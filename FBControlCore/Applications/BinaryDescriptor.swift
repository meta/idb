/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MachO

/// The architecture of a Mach-O slice, named as `lipo` names it.
public struct BinaryArchitecture: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let i386 = BinaryArchitecture(rawValue: "i386")
  public static let x86_64 = BinaryArchitecture(rawValue: "x86_64")
  public static let arm = BinaryArchitecture(rawValue: "arm")
  public static let arm64 = BinaryArchitecture(rawValue: "arm64")

  public var description: String {
    rawValue
  }

  // Encoded as the bare string, as the Objective-C string enum was; a struct's
  // synthesized conformance would wrap it in an object keyed by `rawValue`.

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

enum BinaryDescriptorError: Error, LocalizedError {
  case binaryMissing(path: String)
  case binaryUnreadable(path: String)
  case magicUnrecognized(magic: UInt32, path: String)

  var errorDescription: String? {
    switch self {
    case let .binaryMissing(path):
      return "Binary does not exist at path \(path)"
    case let .binaryUnreadable(path):
      return "Could not fopen file at path \(path)"
    case let .magicUnrecognized(magic, path):
      return "Could not interpret magic '\(magic)' in file \(path)"
    }
  }
}

/// Concrete value wrapper around a binary artifact.
public struct BinaryDescriptor: Hashable, Sendable, CustomStringConvertible {

  /// The name of the executable.
  public let name: String

  /// The supported architectures of the executable.
  public let architectures: Set<BinaryArchitecture>

  /// The `LC_UUID` of the binary, if present.
  public let uuid: UUID?

  /// The file path to the executable.
  public let path: String

  public init(name: String, architectures: Set<BinaryArchitecture>, uuid: UUID?, path: String) {
    self.name = name
    self.architectures = architectures
    self.uuid = uuid
    self.path = path
  }

  /// The descriptor for the binary at `path`, by parsing its Mach-O headers.
  /// Reads the Mach-O binary at `path`.
  public init(path: String) throws {
    guard FileManager.default.fileExists(atPath: path) else {
      throw BinaryDescriptorError.binaryMissing(path: path)
    }
    let file = try MachOFile(path: path)
    self.init(
      name: (path as NSString).lastPathComponent,
      architectures: Set(file.architectures()),
      uuid: file.uuid(),
      path: path
    )
  }

  /// The `LC_RPATH` entries of the binary, in load command order. For a fat binary, those of its first slice.
  public func rpaths() throws -> [String] {
    try MachOFile(path: path).rpaths()
  }

  // The UUID does not take part in equality or hashing.

  public static func == (lhs: BinaryDescriptor, rhs: BinaryDescriptor) -> Bool {
    lhs.name == rhs.name && lhs.path == rhs.path && lhs.architectures == rhs.architectures
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(name)
    hasher.combine(path)
    hasher.combine(architectures)
  }

  public var description: String {
    "Name: \(name) | Path: \(path) | Architectures: \(CollectionInformation.oneLineDescription(from: architectures.map(\.rawValue).sorted()))"
  }
}

/// A memory-mapped Mach-O or fat file, read through bounds-checked unaligned loads.
private struct MachOFile {

  private static let lcUUID: UInt32 = 0x1b
  private static let lcRPath: UInt32 = 0x8000_001c
  private static let architectureByCPUType: [Int32: BinaryArchitecture] = [
    7: .i386,
    0x0100_0007: .x86_64,
    12: .arm,
    0x0100_000c: .arm64,
  ]

  private let data: Data
  private let magic: UInt32

  init(path: String) throws {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
      throw BinaryDescriptorError.binaryUnreadable(path: path)
    }
    self.data = data
    let magic = Self.load(UInt32.self, from: data, at: 0) ?? 0
    guard Self.isFatMagic(magic) || Self.isThinMagic(magic) else {
      throw BinaryDescriptorError.magicUnrecognized(magic: magic, path: path)
    }
    self.magic = magic
  }

  func architectures() -> [BinaryArchitecture] {
    if Self.isFatMagic(magic) {
      var found: [BinaryArchitecture] = []
      _ = enumerateSlices { offset, sliceMagic -> BinaryArchitecture? in
        if let architecture = architecture(at: offset, magic: sliceMagic) {
          found.append(architecture)
        }
        return nil
      }
      return found
    }
    return architecture(at: 0, magic: magic).map { [$0] } ?? []
  }

  func uuid() -> UUID? {
    if Self.isFatMagic(magic) {
      return enumerateSlices { offset, sliceMagic in uuid(at: offset, magic: sliceMagic) }
    }
    return uuid(at: 0, magic: magic)
  }

  func rpaths() -> [String] {
    if Self.isFatMagic(magic) {
      return enumerateSlices { offset, sliceMagic in rpaths(at: offset, magic: sliceMagic) } ?? []
    }
    return rpaths(at: 0, magic: magic)
  }

  // MARK: - Fat files

  /// Visits each slice until `body` returns a value or a slice does not carry Mach-O magic.
  private func enumerateSlices<Value>(_ body: (_ offset: Int, _ magic: UInt32) -> Value?) -> Value? {
    let swap = magic == FAT_CIGAM
    guard let count = load(UInt32.self, at: 4, swap: swap) else {
      return nil
    }
    // fat_header is 8 bytes; each fat_arch is 20, with the slice offset at 8.
    for index in 0..<Int(count) {
      let archOffset = 8 + index * 20
      guard let sliceOffset = load(UInt32.self, at: archOffset + 8, swap: swap),
        let sliceMagic = load(UInt32.self, at: Int(sliceOffset)),
        Self.isThinMagic(sliceMagic)
      else {
        return nil
      }
      if let value = body(Int(sliceOffset), sliceMagic) {
        return value
      }
    }
    return nil
  }

  // MARK: - Thin slices

  private func architecture(at offset: Int, magic: UInt32) -> BinaryArchitecture? {
    guard let cpuType = load(Int32.self, at: offset + 4, swap: Self.isSwapped(magic)) else {
      return nil
    }
    return Self.architectureByCPUType[cpuType]
  }

  private func uuid(at offset: Int, magic: UInt32) -> UUID? {
    enumerateLoadCommands(at: offset, magic: magic) { command, commandOffset, _ in
      guard command == Self.lcUUID, commandOffset + 24 <= data.count else {
        return nil
      }
      var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
      withUnsafeMutableBytes(of: &bytes) { destination in
        _ = unsafe data.copyBytes(to: destination, from: (commandOffset + 8)..<(commandOffset + 24))
      }
      return UUID(uuid: bytes)
    }
  }

  private func rpaths(at offset: Int, magic: UInt32) -> [String] {
    var rpaths: [String] = []
    let swap = Self.isSwapped(magic)
    _ = enumerateLoadCommands(at: offset, magic: magic) { command, commandOffset, commandSize -> Void? in
      guard command == Self.lcRPath, let pathOffset = load(UInt32.self, at: commandOffset + 8, swap: swap) else {
        return nil
      }
      // The path offset is relative to the start of the load command, and the string ends within it.
      let start = commandOffset + Int(pathOffset)
      let end = min(commandOffset + Int(commandSize), data.count)
      guard start < end else {
        return nil
      }
      let bytes = data[start..<end]
      let terminated = bytes.firstIndex(of: 0).map { bytes[bytes.startIndex..<$0] } ?? bytes
      rpaths.append(String(decoding: terminated, as: UTF8.self))
      return nil
    }
    return rpaths
  }

  /// Visits each load command of the slice at `offset` until `body` returns a value.
  private func enumerateLoadCommands<Value>(at offset: Int, magic: UInt32, _ body: (_ command: UInt32, _ offset: Int, _ size: UInt32) -> Value?) -> Value? {
    let swap = Self.isSwapped(magic)
    let headerSize = Self.isMagic64(magic) ? 32 : 28
    guard let count = load(UInt32.self, at: offset + 16, swap: swap) else {
      return nil
    }
    var commandOffset = offset + headerSize
    for _ in 0..<Int(count) {
      guard let command = load(UInt32.self, at: commandOffset, swap: swap),
        let size = load(UInt32.self, at: commandOffset + 4, swap: swap),
        size > 0
      else {
        return nil
      }
      if let value = body(command, commandOffset, size) {
        return value
      }
      commandOffset += Int(size)
    }
    return nil
  }

  // MARK: - Reading

  private func load<Value: FixedWidthInteger>(_ type: Value.Type, at offset: Int, swap: Bool = false) -> Value? {
    guard let value = Self.load(type, from: data, at: offset) else {
      return nil
    }
    return swap ? value.byteSwapped : value
  }

  private static func load<Value: FixedWidthInteger>(_ type: Value.Type, from data: Data, at offset: Int) -> Value? {
    let size = MemoryLayout<Value>.size
    guard offset >= 0, offset + size <= data.count else {
      return nil
    }
    return unsafe data.withUnsafeBytes { unsafe $0.loadUnaligned(fromByteOffset: offset, as: Value.self) }
  }

  private static func isMagic32(_ magic: UInt32) -> Bool {
    magic == MH_MAGIC || magic == MH_CIGAM
  }

  private static func isMagic64(_ magic: UInt32) -> Bool {
    magic == MH_MAGIC_64 || magic == MH_CIGAM_64
  }

  private static func isThinMagic(_ magic: UInt32) -> Bool {
    isMagic32(magic) || isMagic64(magic)
  }

  private static func isFatMagic(_ magic: UInt32) -> Bool {
    magic == FAT_MAGIC || magic == FAT_CIGAM
  }

  private static func isSwapped(_ magic: UInt32) -> Bool {
    magic == MH_CIGAM || magic == MH_CIGAM_64 || magic == FAT_CIGAM
  }
}
