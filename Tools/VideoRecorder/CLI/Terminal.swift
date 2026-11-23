/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import ArgumentParser
import FBControlCore
import FBSimulatorControl
import FBSimulatorVideo
import Foundation
import IOSurface

struct Terminal: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Render a live view of the simulator in this terminal")
  @OptionGroup var target: SimulatorOptions
  @Option(help: "half (default): two colour samples per cell; ascii: a coloured brightness ramp") var mode: TerminalRenderMode = .half
  @Option(help: "Maximum redraws per second; omitted or 0 redraws on every screen update") var fps: UInt?
  @Option(help: "Bits per colour channel, 1 to 8; fewer bits write fewer bytes") var colorBits: Int = 6
  @Option(help: "Largest per-channel change, 0 to 255, that does not redraw a cell") var threshold: UInt8 = 4
  @Flag(inversion: .prefixedNo, help: "Show a status line below the view") var status = true

  func validate() throws {
    if let fps, fps > 1000 {
      throw ValidationError("--fps must be at most 1000")
    }
    guard (1...8).contains(colorBits) else {
      throw ValidationError("--color-bits must be between 1 and 8")
    }
  }

  @MainActor
  mutating func run() async throws {
    // Not stderr: it is usually the same terminal, and log lines would land in the middle of the view.
    let logger = ControlCoreGlobalConfiguration.systemLogger(writingToStderr: false, debugLogging: false)
    let simulator = try target.simulator(logger: logger)
    let framebuffer = try await simulator.framebuffer.connect(display: .active)
    let attachment = try framebuffer.attach()
    let sampler = try TerminalFrameSampler(colorBits: colorBits)

    let source = LatestSurface(attachment.initialSurface)
    let (triggers, trigger) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    trigger.yield()
    let pump = Task {
      defer { trigger.finish() }
      for await event in attachment.events {
        switch event {
        case .surfaceChanged(let surface):
          source.surface = surface
          trigger.yield()
        case .frameRendered:
          trigger.yield()
        case .configurationChanged:
          continue
        case .ended(let error):
          return Optional(error)
        @unknown default:
          continue
        }
      }
      return nil
    }
    let stop = Task {
      await waitForStopSignal()
      trigger.finish()
    }
    let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
    signal(SIGWINCH, SIG_IGN)
    resize.setEventHandler { trigger.yield() }
    resize.resume()

    writeToTerminal("\u{1B}[?1049h\u{1B}[?25l")
    var renderer = TerminalRenderer(
      sampler: sampler, formatter: ANSIFrameFormatter(mode: mode, threshold: threshold),
      minimumInterval: fps.flatMap { $0 > 0 ? .seconds(1) / Int($0) : nil }, showsStatus: status)
    let renderError: (any Error)?
    do {
      try await renderer.run(triggers: triggers, source: source)
      renderError = nil
    } catch {
      renderError = error
    }
    writeToTerminal("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")

    resize.cancel()
    stop.cancel()
    attachment.cancel()
    if let ended = await pump.value {
      FileHandle.standardError.write(Data("Stopped: \(ended.localizedDescription)\n".utf8))
    }
    if let renderError {
      throw renderError
    }
  }
}

// Buck builds this tool outside the `idb` package its libraries share, so the conformance is retroactive
// there but not in the open-source build, where `@retroactive` is an error. Module-qualified names say
// the conformance is intended in both.
extension FBSimulatorVideo.TerminalRenderMode: ArgumentParser.ExpressibleByArgument {}

/// The framebuffer's current surface, written by the event pump and read by the renderer. Kept out
/// of the trigger stream so that coalescing triggers can never drop a surface change.
// SAFETY: every access to `stored` is behind `lock`.
// patternlint-disable-next-line unchecked-sendable
private final class LatestSurface: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: IOSurface?

  init(_ surface: IOSurface?) {
    stored = surface
  }

  var surface: IOSurface? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

/// Draws a frame per trigger, so output follows the screen's own frame rate, no more often than
/// `minimumInterval` when one is given. Triggers that arrive while a frame is being drawn collapse
/// into one, so a slow terminal skips frames rather than falling behind.
private struct TerminalRenderer {
  let sampler: TerminalFrameSampler
  var formatter: ANSIFrameFormatter
  let minimumInterval: Duration?
  let showsStatus: Bool

  private var attachedSurfaceID: IOSurfaceID?
  private var lastDraw: ContinuousClock.Instant?
  private var lastGrid: TerminalGrid?
  private var writtenStatus: String?
  private var windowStart = ContinuousClock.now
  private var windowFrames = 0
  private var windowBytes = 0
  private var measurementText = ""

  init(sampler: TerminalFrameSampler, formatter: ANSIFrameFormatter, minimumInterval: Duration?, showsStatus: Bool) {
    self.sampler = sampler
    self.formatter = formatter
    self.minimumInterval = minimumInterval
    self.showsStatus = showsStatus
  }

  @concurrent
  mutating func run(triggers: AsyncStream<Void>, source: LatestSurface) async throws {
    for await _ in triggers {
      if let lastDraw, let minimumInterval {
        try? await Task.sleep(until: lastDraw + minimumInterval)
      }
      lastDraw = .now
      try draw(surface: source.surface)
    }
  }

  private mutating func draw(surface: IOSurface?) throws {
    let surfaceID = surface.map { IOSurfaceGetID($0) }
    if surfaceID != attachedSurfaceID {
      try sampler.attach(surface)
      attachedSurfaceID = surfaceID
      formatter.invalidate()
      writtenStatus = nil
    }
    guard let (width, height) = sampler.surfaceSize else { return }
    let (columns, rows) = terminalSize()
    let grid = TerminalGrid.fitting(
      surfaceWidth: width, surfaceHeight: height, terminalColumns: columns, terminalRows: showsStatus ? max(1, rows - 1) : rows)
    guard let cells = try sampler.sample(grid: grid) else { return }
    var output = formatter.format(cells, grid: grid)
    if grid != lastGrid {
      lastGrid = grid
      writtenStatus = nil
    }
    // The status line changes at most once a second, so a still screen writes nothing at all.
    if showsStatus {
      let status = statusText(width: width, height: height, grid: grid, frameBytes: output.count)
      if status != writtenStatus {
        output += Array("\u{1B}[\(grid.rows + 1);1H\u{1B}[2K\(status)".utf8)
        writtenStatus = status
      }
    }
    guard !output.isEmpty else { return }
    writeToTerminal(output)
  }

  private mutating func statusText(width: Int, height: Int, grid: TerminalGrid, frameBytes: Int) -> String {
    windowBytes += frameBytes
    if frameBytes > 0 {
      windowFrames += 1
    }
    let elapsed = ContinuousClock.now - windowStart
    if elapsed >= .seconds(1) {
      let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      measurementText = unsafe String(
        format: "gpu %.2f ms | %.0f fps, %.1f KB/s", sampler.lastGPUDuration * 1000, Double(windowFrames) / seconds,
        Double(windowBytes) / 1024 / seconds)
      windowStart = .now
      windowFrames = 0
      windowBytes = 0
    }
    return "\(width)x\(height) -> \(grid.columns)x\(grid.rows) | \(measurementText)"
  }
}

private func terminalSize() -> (columns: Int, rows: Int) {
  var size = winsize()
  guard unsafe ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
    return (80, 24)
  }
  return (Int(size.ws_col), Int(size.ws_row))
}

private func writeToTerminal(_ string: String) {
  writeToTerminal(Array(string.utf8))
}

private func writeToTerminal(_ bytes: [UInt8]) {
  FileHandle.standardOutput.write(Data(bytes))
}
