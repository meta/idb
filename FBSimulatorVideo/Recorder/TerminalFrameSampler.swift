/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreVideo
import Foundation
import IOSurface
import Metal

public enum TerminalFrameSamplerError: Error, LocalizedError {
  case noMetalDevice
  case unsupportedPixelFormat(OSType)
  case failedToCreateTexture
  case failedToEncode

  public var errorDescription: String? {
    switch self {
    case .noMetalDevice:
      return "No Metal device is available"
    case .unsupportedPixelFormat(let format):
      return unsafe String(format: "Unsupported framebuffer pixel format 0x%08x; expected BGRA", format)
    case .failedToCreateTexture:
      return "Failed to create a texture over the framebuffer surface"
    case .failedToEncode:
      return "Failed to encode the sampling pass"
    }
  }
}

/// Samples a BGRA IOSurface into one `TerminalCell` per grid cell on the GPU. The texture aliases
/// the surface's memory, so it is rebuilt only when the surface itself is replaced, not per frame.
public final class TerminalFrameSampler {
  /// The surface's size, or nil when no surface is attached.
  public private(set) var surfaceSize: (width: Int, height: Int)?
  /// GPU time of the last `sample`, in seconds.
  public private(set) var lastGPUDuration: TimeInterval = 0

  private let device: any MTLDevice
  private let queue: any MTLCommandQueue
  private let pipeline: any MTLComputePipelineState
  private let levels: Float
  private var texture: (any MTLTexture)?
  private var output: (any MTLBuffer)?

  /// `colorBits` quantizes each channel to that many bits (1–8). Coarser colours make more cells
  /// identical between frames and between neighbours, which shrinks the ANSI output.
  public init(colorBits: Int = 8) throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw TerminalFrameSamplerError.noMetalDevice
    }
    guard let queue = device.makeCommandQueue() else {
      throw TerminalFrameSamplerError.failedToEncode
    }
    let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
    guard let function = library.makeFunction(name: "sample_cells") else {
      throw TerminalFrameSamplerError.failedToEncode
    }
    self.device = device
    self.queue = queue
    pipeline = try device.makeComputePipelineState(function: function)
    levels = Float((1 << min(max(colorBits, 1), 8)) - 1)
  }

  public func attach(_ surface: IOSurface?) throws {
    guard let surface else {
      texture = nil
      surfaceSize = nil
      return
    }
    let format = IOSurfaceGetPixelFormat(surface)
    guard format == kCVPixelFormatType_32BGRA else {
      throw TerminalFrameSamplerError.unsupportedPixelFormat(format)
    }
    let width = IOSurfaceGetWidth(surface)
    let height = IOSurfaceGetHeight(surface)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
      throw TerminalFrameSamplerError.failedToCreateTexture
    }
    self.texture = texture
    surfaceSize = (width, height)
  }

  /// Samples the attached surface into `grid`, or returns nil when no surface is attached.
  public func sample(grid: TerminalGrid) throws -> [TerminalCell]? {
    guard let texture else { return nil }
    let length = grid.cellCount * MemoryLayout<TerminalCell>.stride
    if (output?.length ?? 0) < length {
      output = device.makeBuffer(length: length, options: .storageModeShared)
    }
    var parameters = Parameters(columns: UInt32(grid.columns), rows: UInt32(grid.rows), levels: levels)
    guard let output,
      let commands = queue.makeCommandBuffer(),
      let encoder = commands.makeComputeCommandEncoder()
    else {
      throw TerminalFrameSamplerError.failedToEncode
    }
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    encoder.setBuffer(output, offset: 0, index: 0)
    unsafe encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 1)
    encoder.dispatchThreads(
      MTLSize(width: grid.columns, height: grid.rows, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()
    if let error = commands.error {
      throw error
    }
    lastGPUDuration = commands.gpuEndTime - commands.gpuStartTime
    let cells = unsafe output.contents().bindMemory(to: TerminalCell.self, capacity: grid.cellCount)
    return unsafe Array(UnsafeBufferPointer(start: cells, count: grid.cellCount))
  }

  /// Matches `Parameters` in the kernel source.
  private struct Parameters {
    var columns: UInt32
    var rows: UInt32
    var levels: Float
  }

  private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters { uint columns; uint rows; float levels; };
    struct Cell { uchar4 top; uchar4 bottom; };

    // Box-average of a source region, strided so a large cell costs at most ~16x16 reads.
    static float3 average(texture2d<float, access::read> source, uint2 origin, uint2 size) {
      uint2 step = max(uint2(1), size / 16);
      float3 sum = 0;
      uint count = 0;
      for (uint y = origin.y; y < origin.y + size.y; y += step.y) {
        for (uint x = origin.x; x < origin.x + size.x; x += step.x) {
          sum += source.read(uint2(x, y)).rgb;
          count++;
        }
      }
      return sum / float(max(count, 1u));
    }

    static uchar4 quantize(float3 color, float levels) {
      return uchar4(uchar3(round(color * levels) / levels * 255.0 + 0.5), 255);
    }

    kernel void sample_cells(texture2d<float, access::read> source [[texture(0)]],
                             device Cell *cells [[buffer(0)]],
                             constant Parameters &parameters [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
      if (gid.x >= parameters.columns || gid.y >= parameters.rows) return;
      uint width = source.get_width();
      uint height = source.get_height();
      uint pixelRows = parameters.rows * 2;
      // Integer bounds, so adjacent cells tile the source with no gaps or overlap.
      uint x0 = gid.x * width / parameters.columns;
      uint x1 = (gid.x + 1) * width / parameters.columns;
      uint yTop = (gid.y * 2) * height / pixelRows;
      uint yMiddle = (gid.y * 2 + 1) * height / pixelRows;
      uint yBottom = (gid.y * 2 + 2) * height / pixelRows;
      uint cellWidth = max(x1 - x0, 1u);
      float3 top = average(source, uint2(x0, yTop), uint2(cellWidth, max(yMiddle - yTop, 1u)));
      float3 bottom = average(source, uint2(x0, yMiddle), uint2(cellWidth, max(yBottom - yMiddle, 1u)));
      cells[gid.y * parameters.columns + gid.x] = Cell { quantize(top, parameters.levels), quantize(bottom, parameters.levels) };
    }
    """
}
