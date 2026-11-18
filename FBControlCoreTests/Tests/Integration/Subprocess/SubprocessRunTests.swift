/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FBControlCore
import Foundation
import Testing

/// Covers `Subprocess.run`: what each output captures, the child's
/// environment and descriptors, how termination is reported, the deadline,
/// and the exit policy.
///
/// Serialized: running every test's child concurrently under suite load
/// produces transient launch failures.
@Suite(.serialized)
struct SubprocessRunTests {

  private static func new(_ script: String) -> Subprocess {
    Subprocess(executable: "/bin/sh", arguments: ["-c", script])
  }

  // MARK: - Captures

  @Test("A string capture returns stdout")
  func stringCaptureReturnsStdout() async throws {
    let new = try await Self.new("printf 'out'").run(output: .string, error: .closed)

    #expect(new.standardOutput == "out")
    #expect(new.terminationStatus == .exited(0))
  }

  @Test("A stderr capture returns stderr")
  func stderrCaptureReturnsStderr() async throws {
    let new = try await Self.new("printf 'err' 1>&2").run(output: .closed, error: .string)

    #expect(new.standardError == "err")
  }

  @Test("A data capture returns the raw bytes")
  func dataCaptureReturnsTheBytes() async throws {
    let new = try await Self.new("printf 'bytes'").run(output: .data, error: .closed)

    #expect(new.standardOutput == Data("bytes".utf8))
  }

  @Test("A file capture writes stdout to an existing file")
  func fileCaptureWritesToAnExistingFile() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SubprocessRunTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let newPath = directory.appendingPathComponent("new.txt")
    #expect(FileManager.default.createFile(atPath: newPath.path, contents: nil))

    let new = try await Self.new("/usr/bin/seq 1 3").run(output: .file(newPath), error: .closed)

    #expect(new.standardOutput == newPath)
    #expect(try String(contentsOf: newPath, encoding: .utf8) == "1\n2\n3\n")
  }

  @Test("A line sink delivers every callback before termination", arguments: [false, true], [false, true])
  func lineSinkReceivesEachLine(standardError: Bool, trailingNewline: Bool) async throws {
    // SAFETY: `lines` is the only mutable state and every read and write of it
    // goes through `lock`; the line sinks call in from arbitrary queues.
    // patternlint-disable-next-line unchecked-sendable
    final class Collected: @unchecked Sendable {
      private let lock = NSLock()
      private var lines: [String] = []
      func append(_ line: String) { lock.withLock { lines.append(line) } }
      var snapshot: [String] { lock.withLock { lines } }
    }
    let newLines = Collected()
    let expected = (0..<1024).map(String.init)
    let padding = String(repeating: " ", count: 128)
    let payload = expected.map { padding + $0 + padding }.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    let output = Subprocess.Output<Void>.lines {
      newLines.append(String($0.split(whereSeparator: \.isWhitespace).first ?? ""))
    }

    _ = try await Self.new(standardError ? "/bin/cat >&2" : "/bin/cat").run(
      output: standardError ? .closed : output,
      error: standardError ? output : .closed,
      input: .data(Data(payload.utf8)))

    // No polling: termination is the barrier for callbacks, including the
    // final unterminated line flushed at EOF.
    #expect(newLines.snapshot == expected)
  }

  @Test("Cancelling a termination waiter leaves line delivery active")
  func cancelledWaiterDoesNotStopLineDelivery() async throws {
    let input = InputSource()
    let entered = AsyncEvent<Void>()
    let delivered = AsyncEvent<String>()

    try await Self.new("/bin/cat").withRunning(
      output: .lines { line in
        if line == "first" {
          entered.happen()
        } else {
          delivered.happen(line)
        }
      },
      error: .closed,
      input: .source(input)
    ) { running in
      defer { input.finish() }
      let observer = Task { try await running.terminationStatus }
      input.write(Data("first\n".utf8))
      try await entered.wait()
      observer.cancel()
      do {
        _ = try await observer.value
        Issue.record("A cancelled waiter completed normally")
      } catch is CancellationError {
      }
      input.write(Data("after cancellation\n".utf8))
      input.finish()
      #expect(try await running.terminationStatus == .exited(0))
      #expect(try delivered.result?.get() == "after cancellation")
    }
  }

  @Test("An unconfigured run captures both streams as strings")
  func unconfiguredRunCapturesBothStreams() async throws {
    let new = try await Self.new("printf 'out'; printf 'err' 1>&2").run()

    #expect(new.standardOutput == "out")
    #expect(new.standardError == "err")
    #expect(new.terminationStatus == .exited(0))
  }

  @Test("A logged stream reaches the logger once")
  func loggerSinkDeliversEachChunkOnce() async throws {
    let logged = ConsumableBuffer()
    let logger = ConsumerLogger(consumer: logged)

    _ = try await Self.new("printf 'logged\\n'").run(output: .logger(logger), error: .closed)

    #expect(logged.consumeLineString() == "logged")
    #expect(logged.consumeLineString() == nil)
  }

  @Test("An error-message capture logs the whole stream and returns its tail")
  func errorMessageCaptureLogsAndReturnsTheTail() async throws {
    let logged = ConsumableBuffer()
    let logger = ConsumerLogger(consumer: logged)

    let new = try await Self.new("printf 'boom\\n' 1>&2")
      .run(output: .closed, error: .loggerCapturingErrorMessage(logger))

    #expect(new.standardError == "boom")
    #expect(logged.consumeLineString() == "boom")
  }

  @Test("An error-message capture retains only the last bytes of a long stream")
  func errorMessageCaptureRetainsOnlyTheTail() async throws {
    let logger = ConsumerLogger(consumer: ConsumableBuffer())
    let total = Subprocess.errorMessageLength * 2

    let new = try await Self.new("/usr/bin/head -c \(total) /dev/zero | /usr/bin/tr '\\0' 'x' 1>&2")
      .run(output: .closed, error: .loggerCapturingErrorMessage(logger))

    #expect(new.standardError == String(repeating: "x", count: Subprocess.errorMessageLength))
  }

  @Test("A file the capture creates itself is readable afterwards")
  func fileCaptureCreatesAReadableFile() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SubprocessRunTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("created.txt")

    _ = try await Self.new("printf 'created'").run(output: .file(path), error: .closed)

    #expect(try String(contentsOf: path, encoding: .utf8) == "created")
  }

  // MARK: - Environment

  @Test("An exact environment reaches the child")
  func exactEnvironmentReachesTheChild() async throws {
    var spec = Self.new("/usr/bin/env")
    spec.environment = .exact(["FOO": "BAR"])
    let new = try await spec.run(output: .string, error: .closed)

    #expect(new.standardOutput.contains("FOO=BAR"))
  }

  // MARK: - The two dev nulls

  @Test("A closed output leaves the child's descriptor closed")
  func closedOutputLeavesTheDescriptorClosed() async throws {
    // `/dev/fd/1` exists only while fd 1 is open in the child, so `test -e`
    // discriminates a closed descriptor (exit 1) from any open sink (exit 0).
    let new = try await Self.new("test -e /dev/fd/1").run(output: .closed, error: .closed, exitPolicy: .any)

    #expect(new.terminationStatus == .exited(1))
  }

  @Test("A null-device output hands the child an open descriptor")
  func nullDeviceOutputIsOpenOnTheHost() async throws {
    let new = try await Self.new("test -e /dev/fd/1").run(output: .nullDevice, error: .closed, exitPolicy: .any)

    #expect(new.terminationStatus == .exited(0))
  }

  // MARK: - Termination

  @Test(
    "Any-policy runs report the exit code",
    arguments: [Int32(0), Int32(3), Int32(149)])
  func anyPolicyReportsTheExitCode(code: Int32) async throws {
    let new = try await Self.new("exit \(code)").run(output: .closed, error: .closed, exitPolicy: .any)

    #expect(new.terminationStatus == .exited(code))
  }

  @Test("A signalled process reports the signal")
  func signalledProcessReportsTheSignal() async throws {
    let new = try await Self.new("kill -TERM $$").run(output: .closed, error: .closed, exitPolicy: .any)

    #expect(new.terminationStatus == .signalled(SIGTERM))
  }

  // MARK: - Deadline

  @Test("A process that outlives the deadline throws, and keeps running unkilled")
  func timeoutAbandonsWithoutKilling() async throws {
    do {
      _ = try await Self.new("sleep 10000").run(output: .closed, error: .closed, exitPolicy: .any, timeout: 0.3)
      Issue.record("Expected the deadline to fire")
    } catch let SubprocessError.timedOut(seconds, _, processIdentifier) {
      #expect(seconds == 0.3)
      // The deadline stops observation, it does not kill.
      #expect(kill(processIdentifier, 0) == 0)
      kill(processIdentifier, SIGKILL)
    } catch {
      Issue.record("Expected a timedOut error, got: \(error)")
    }
  }

  @Test("A process that terminates within the deadline completes normally")
  func completionWithinTheDeadlineIsUnaffected() async throws {
    let result = try await Self.new("printf 'quick'").run(output: .string, error: .closed, timeout: 20)

    #expect(result.standardOutput == "quick")
    #expect(result.terminationStatus == .exited(0))
  }

  // MARK: - Policy rejection

  @Test("An exit code outside the policy's list throws")
  func policyRejectsAnUnlistedExitCode() async throws {
    do {
      _ = try await Self.new("exit 149").run(output: .closed, error: .closed, exitPolicy: .mustExit([0]))
      Issue.record("Expected the code-list policy to reject exit 149")
    } catch let SubprocessError.unacceptableTermination(status, _, _, _, _) {
      #expect(status == .exited(149))
    } catch {
      Issue.record("Expected an unacceptableTermination error, got: \(error)")
    }
  }

  @Test("A rejected exit quotes the error-message capture")
  func policyRejectionQuotesTheErrorMessageCapture() async throws {
    let script = "printf 'no space left on device\\n' 1>&2; exit 3"
    let logger = ConsumerLogger(consumer: ConsumableBuffer())

    let new = await #expect(throws: SubprocessError.self) {
      _ = try await Self.new(script).run(output: .closed, error: .loggerCapturingErrorMessage(logger))
    }

    #expect(new?.localizedDescription.contains("no space left on device") == true)
  }

  @Test("A rejected exit quotes an error-message capture that is not valid UTF-8")
  func policyRejectionQuotesAnErrorMessageThatIsNotValidUTF8() async throws {
    // `\351` is a Latin-1 é, which is not valid UTF-8.
    let script = "printf 'caf\\351: no space left on device' 1>&2; exit 3"
    let logger = ConsumerLogger(consumer: ConsumableBuffer())

    let new = await #expect(throws: SubprocessError.self) {
      _ = try await Self.new(script).run(output: .closed, error: .loggerCapturingErrorMessage(logger))
    }

    #expect(new?.localizedDescription.contains("no space left on device") == true)
  }

  @Test("A signal fails a zero-exit policy")
  func zeroExitPolicyRejectsASignal() async throws {
    do {
      _ = try await Self.new("kill -9 $$").run(output: .closed, error: .closed)
      Issue.record("Expected the zero-exit policy to reject a signalled process")
    } catch let SubprocessError.unacceptableTermination(status, _, _, _, _) {
      #expect(status == .signalled(SIGKILL))
    } catch {
      Issue.record("Expected an unacceptableTermination error, got: \(error)")
    }
  }
}
