/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import FBControlCore
import Foundation
import MobileDeviceAPI

private typealias HeaderIntType = UInt32
private let HeaderLength = MemoryLayout<HeaderIntType>.size

/// There is an upper limit on the number of bytes that can be moved at once.
private let ReadBufferSize = 1024 * 4
private let SendBufferSize = 1024 * 4

/// How long invalidation waits for an in-flight read loop to exit before the underlying connection
/// is released.
private let ReaderDrainTimeout: TimeInterval = 5

public enum LockdownServiceConnectionError: Error {
  case sendMessageFailed(errorText: String, message: String, code: Int32)
  case receiveMessageFailed(errorText: String, code: Int32)
  case receivedNoMessage
  case noConnectionToInvalidate
  case invalidateFailed(connection: String, errorText: String)
  case sendFailed(bytes: Int, reason: String)
  case sentMoreThanRemained(sent: Int, remaining: Int)
  case sendIncomplete(requested: Int, remaining: Int)
  case receiveFailed(bytes: Int, reason: String)
  case readMoreThanRemained(read: Int, remaining: Int)
  case receiveIncomplete(requested: Int, remaining: Int)
  case receiveUpToFailed(size: Int, reason: String)
  case cannotStartReading(state: UInt)
}

extension LockdownServiceConnectionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .sendMessageFailed(errorText, message, code):
      return "Failed to send message \(errorText) (\(message) code \(code))"
    case let .receiveMessageFailed(errorText, code):
      return "Failed to receive message (\(errorText)): code \(code)"
    case .receivedNoMessage:
      return "Receiving a message succeeded without a message"
    case .noConnectionToInvalidate:
      return "No connection to invalidate"
    case let .invalidateFailed(connection, errorText):
      return "Failed to invalidate connection \(connection) with error \(errorText)"
    case let .sendFailed(bytes, reason):
      return "Failure in send of \(bytes) bytes: \(reason)"
    case let .sentMoreThanRemained(sent, remaining):
      return "Failure in send: Sent \(sent) bytes but only \(remaining) bytes remaining"
    case let .sendIncomplete(requested, remaining):
      return "Failed to send \(requested) bytes, \(remaining) remaining"
    case let .receiveFailed(bytes, reason):
      return "Failure in receive of \(bytes) bytes: \(reason)"
    case let .readMoreThanRemained(read, remaining):
      return "Failure in receive: Read \(read) bytes but only \(remaining) bytes remaining"
    case let .receiveIncomplete(requested, remaining):
      return "Failed to receive \(requested) bytes, \(remaining) remaining to read and eof reached."
    case let .receiveUpToFailed(size, reason):
      return "Failure in receive of up to \(size) bytes: \(reason)"
    case let .cannotStartReading(state):
      return "Cannot start reading in state \(state)"
    }
  }
}

/// An AMDServiceConnection is a connection to a "lockdown" service over USB.
// @safe: The connection reference is invalidated only here; callers only see the object.
@safe public final class LockdownServiceConnection: CustomStringConvertible {

  // MARK: - Properties

  public let name: String
  public let device: AMDevice
  public let calls: AMDCalls
  public let logger: (any ControlCoreLogger)?

  /// Held unretained: MobileDevice hands the connection over at +1 and `invalidate` is what gives
  /// that back. Retaining it here would leave the release unbalanced.
  private var connectionRef: Unmanaged<AnyObject>?

  private var activeReaderFinished: AsyncEvent<Void>?

  var readerDrainTimeout = ReaderDrainTimeout

  public var connection: AMDServiceConnection? {
    unsafe connectionRef?.takeUnretainedValue()
  }

  // MARK: - Initializers

  public init(
    name: String,
    connection: AMDServiceConnection,
    device: AMDevice,
    calls: AMDCalls,
    logger: (any ControlCoreLogger)?
  ) {
    // Raw transfer is used when there is no secure context, otherwise the service connection
    // wrapping must be used.
    let secureIOContext = calls.ServiceConnectionGetSecureIOContext(connection)
    logger?.log(unsafe "Constructing service connection for \(name) \(secureIOContext != nil ? "is" : "is not") Secure")
    self.name = name
    unsafe self.connectionRef = unsafe Unmanaged.passUnretained(connection as AnyObject)
    self.device = device
    self.calls = calls
    self.logger = logger
  }

  public var description: String {
    "\(name) \(String(describing: connection))"
  }

  // MARK: - plist Messaging

  func sendMessage(_ message: Any) throws {
    let result = calls.ServiceConnectionSendMessage(
      connection, message as CFPropertyList, CFPropertyListFormat.binaryFormat_v1_0, nil, nil, nil)
    guard result == 0 else {
      throw LockdownServiceConnectionError.sendMessageFailed(
        errorText: errorText(result), message: String(describing: message), code: result)
    }
  }

  func receiveMessage() throws -> Any {
    var message: Unmanaged<CFPropertyList>?
    let result = unsafe calls.ServiceConnectionReceiveMessage(connection, &message, nil, nil, nil, nil)
    guard result == 0 else {
      throw LockdownServiceConnectionError.receiveMessageFailed(errorText: errorText(result), code: result)
    }
    guard let message = unsafe message else {
      throw LockdownServiceConnectionError.receivedNoMessage
    }
    return unsafe message.takeRetainedValue()
  }

  func sendAndReceiveMessage(_ message: Any) throws -> Any {
    try sendMessage(message)
    return try receiveMessage()
  }

  // MARK: - Lifecycle

  func invalidate() async throws {
    guard let connectionRef = unsafe connectionRef else {
      throw LockdownServiceConnectionError.noConnectionToInvalidate
    }
    let reference = unsafe connectionRef.takeUnretainedValue()
    let connectionDescription = CFCopyDescription(reference) as String? ?? "unknown"
    logger?.log("Invalidating Connection \(connectionDescription)")
    let status = calls.ServiceConnectionInvalidate(reference)
    guard status == 0 else {
      throw LockdownServiceConnectionError.invalidateFailed(
        connection: connectionDescription, errorText: errorText(status))
    }
    logger?.log("Invalidated connection \(connectionDescription)")
    // The read loop may still be inside ServiceConnectionReceive; the invalidation above unblocks
    // it, but the connection must stay alive until the loop has actually exited — releasing it
    // mid-read reads freed memory inside the SSL layer.
    var drained = true
    if let activeReaderFinished {
      drained = (try? await activeReaderFinished.wait(timeout: readerDrainTimeout, waitingFor: "the reader to drain")) != nil
    }
    // AMDServiceConnectionInvalidate does not release the connection. If the reader did not
    // drain, leak rather than release: releasing under a still-blocked read is a use-after-free.
    if drained {
      unsafe connectionRef.release()
    } else {
      logger?.log("Reader did not drain within \(readerDrainTimeout)s; leaking the connection rather than freeing it under an active read")
    }
    unsafe self.connectionRef = nil
  }

  // MARK: - AFC

  func asAFCConnection(
    calls afcCalls: AFCCalls,
    callback: @escaping AFCNotificationCallback,
    logger: any ControlCoreLogger
  ) -> FileConduit {
    let afcConnection = unsafe afcCalls.Create(nil, calls.ServiceConnectionGetSocket(connection), nil, callback, nil)
    let afcReference = unsafe afcConnection?.takeUnretainedValue()
    if let secureIOContext = calls.ServiceConnectionGetSecureIOContext(connection), let afcReference {
      unsafe afcCalls.SetSecureContext(afcReference, secureIOContext)
    }
    return FileConduit(connection: afcReference, calls: afcCalls, logger: self.logger)
  }

  // MARK: - Sending

  public func send(_ data: Data) throws {
    var bytesRemaining = data.count
    while bytesRemaining > 0 {
      let start = data.count - bytesRemaining
      let length = min(SendBufferSize, bytesRemaining)
      let result = unsafe data.withUnsafeBytes { buffer -> Int32 in
        // Only an empty payload has no base address, and the loop cannot be entered for one.
        guard let base = buffer.baseAddress else {
          return 0
        }
        return unsafe send(base.advanced(by: start), size: length)
      }
      if result == -1 {
        throw unsafe LockdownServiceConnectionError.sendFailed(bytes: length, reason: String(cString: strerror(errno)))
      }
      if result == 0 {
        break
      }
      let sentBytes = Int(result)
      guard sentBytes <= bytesRemaining else {
        throw LockdownServiceConnectionError.sentMoreThanRemained(sent: sentBytes, remaining: bytesRemaining)
      }
      bytesRemaining -= sentBytes
    }
    guard bytesRemaining == 0 else {
      throw LockdownServiceConnectionError.sendIncomplete(requested: data.count, remaining: bytesRemaining)
    }
  }

  public func send(withLengthHeader data: Data) throws {
    let lengthWire = HeaderIntType(data.count).bigEndian
    try send(withUnsafeBytes(of: lengthWire) { unsafe Data($0) })
    try send(data)
  }

  func sendUnsignedInt32(_ value: UInt32) throws {
    try send(withUnsafeBytes(of: value) { unsafe Data($0) })
  }

  // MARK: - Receiving

  public func receive(_ size: Int) throws -> Data {
    var data = Data()
    try enumerateReceive(ofLength: size, chunkSize: ReadBufferSize) { chunk in
      data.append(chunk)
    }
    return data
  }

  public func receive(_ size: Int, toFile fileHandle: FileHandle) throws {
    try enumerateReceive(ofLength: size, chunkSize: ReadBufferSize) { chunk in
      fileHandle.write(chunk)
    }
  }

  public func receive(_ destination: UnsafeMutableRawPointer, ofSize size: Int) throws {
    let data = try receive(size)
    unsafe data.withUnsafeBytes { source in
      guard let base = source.baseAddress else { return }
      unsafe destination.copyMemory(from: base, byteCount: data.count)
    }
  }

  func receiveUp(to size: Int) throws -> Data {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UInt8>.alignment)
    defer { unsafe buffer.deallocate() }
    let result = unsafe receive(buffer, size: size)
    if result == 0 {
      return Data()
    }
    if result == -1 {
      throw unsafe LockdownServiceConnectionError.receiveUpToFailed(size: size, reason: String(cString: strerror(errno)))
    }
    return unsafe Data(bytes: buffer, count: Int(result))
  }

  func receiveUnsignedInt32(_ valueOut: UnsafeMutablePointer<UInt32>) throws {
    unsafe try receive(valueOut, ofSize: MemoryLayout<UInt32>.size)
  }

  func receiveUnsignedInt64(_ valueOut: UnsafeMutablePointer<UInt64>) throws {
    unsafe try receive(valueOut, ofSize: MemoryLayout<UInt64>.size)
  }

  // MARK: - Streams

  func readFromConnectionWriting(
    to consumer: any DataConsumer,
    on queue: DispatchQueue
  ) -> LockdownServiceConnectionReader {
    let reader = LockdownServiceConnectionReader(connection: self, consumer: consumer) { queue.async(execute: $0) }
    activeReaderFinished = reader.finishedReading
    return reader
  }

  // MARK: - Private

  fileprivate func send(_ buffer: UnsafeRawPointer, size: Int) -> Int32 {
    unsafe calls.ServiceConnectionSend(connection, buffer, size)
  }

  fileprivate func receive(_ buffer: UnsafeMutableRawPointer, size: Int) -> Int32 {
    unsafe calls.ServiceConnectionReceive(connection, buffer, size)
  }

  private func errorText(_ status: Int32) -> String {
    unsafe calls.CopyErrorText(status)?.takeRetainedValue() as String? ?? "Unknown error"
  }

  private func enumerateReceive(ofLength size: Int, chunkSize: Int, enumerator: (Data) -> Void) throws {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: MemoryLayout<UInt8>.alignment)
    defer { unsafe buffer.deallocate() }

    var bytesRemaining = size
    while bytesRemaining > 0 {
      let maxReadBytes = min(chunkSize, bytesRemaining)
      let result = unsafe receive(buffer, size: maxReadBytes)
      if result == 0 {
        break
      }
      if result == -1 {
        throw unsafe LockdownServiceConnectionError.receiveFailed(
          bytes: maxReadBytes, reason: String(cString: strerror(errno)))
      }
      let readBytes = Int(result)
      guard readBytes <= bytesRemaining else {
        throw LockdownServiceConnectionError.readMoreThanRemained(read: readBytes, remaining: bytesRemaining)
      }
      bytesRemaining -= readBytes
      unsafe enumerator(Data(bytesNoCopy: buffer, count: readBytes, deallocator: .none))
    }

    guard bytesRemaining == 0 else {
      throw LockdownServiceConnectionError.receiveIncomplete(requested: size, remaining: bytesRemaining)
    }
  }
}

/// Reads a service connection until it is exhausted, feeding a consumer.
final class LockdownServiceConnectionReader {

  private let connection: LockdownServiceConnection
  private let consumer: any DataConsumer
  private let schedule: (@escaping () -> Void) -> Void

  /// Happens once the read loop has exited and delivered end-of-file.
  let finishedReading = AsyncEvent<Void>()

  enum State: UInt {
    case notStarted = 0
    case reading = 1
    case finishedReadingNormally = 2
  }

  /// Locked rather than a bare stored property: the read loop polls this from its own thread while
  /// `startReading` writes it from whichever thread the caller is on.
  private let stateLock = NSLock()
  private var stateStorage = State.notStarted

  private(set) var state: State {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return stateStorage
    }
    set {
      stateLock.lock()
      defer { stateLock.unlock() }
      stateStorage = newValue
    }
  }

  /// `schedule` runs the read loop; it is a closure rather than a queue so tests can run the loop inline.
  init(connection: LockdownServiceConnection, consumer: any DataConsumer, schedule: @escaping (@escaping () -> Void) -> Void) {
    self.connection = connection
    self.consumer = consumer
    self.schedule = schedule
  }

  func startReading() throws {
    guard state == .notStarted else {
      throw LockdownServiceConnectionError.cannotStartReading(state: state.rawValue)
    }

    state = .reading
    schedule { [self] in
      let buffer = UnsafeMutableRawPointer.allocate(byteCount: ReadBufferSize, alignment: MemoryLayout<UInt8>.alignment)
      defer { unsafe buffer.deallocate() }
      while state == .reading {
        let readBytes = unsafe connection.receive(buffer, size: ReadBufferSize)
        if readBytes < 1 {
          break
        }
        unsafe consumer.consumeData(Data(bytes: buffer, count: Int(readBytes)))
      }
      consumer.consumeEndOfFile()
      state = .finishedReadingNormally
      finishedReading.happen()
    }
  }
}
