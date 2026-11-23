/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import CoreAudio
import Foundation
import ShimulatorAudioInjectionCore
import ShimulatorAudioInjectionPrivate

// @safe: Holds only the HAL's function pointers; each call through them is marked `unsafe` where it is made.
@safe public struct AudioHAL: Sendable {
  public typealias CreateIOProcID =
    @convention(c) (
      IDBAudioObjectID, IDBAudioDeviceIOProc?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) -> OSStatus
  public typealias DestroyIOProcID = @convention(c) (IDBAudioObjectID, UnsafeMutableRawPointer?) -> OSStatus
  public typealias GetPropertyData =
    @convention(c) (
      IDBAudioObjectID, UnsafePointer<IDBAudioObjectPropertyAddress>?, UInt32, UnsafeRawPointer?,
      UnsafeMutablePointer<UInt32>?, UnsafeMutableRawPointer?
    ) -> OSStatus
  public typealias GetPropertyDataSize =
    @convention(c) (
      IDBAudioObjectID, UnsafePointer<IDBAudioObjectPropertyAddress>?, UInt32, UnsafeRawPointer?,
      UnsafeMutablePointer<UInt32>?
    ) -> OSStatus
  public typealias HasProperty = @convention(c) (IDBAudioObjectID, UnsafePointer<IDBAudioObjectPropertyAddress>?) -> Bool
  public typealias AddPropertyListener =
    @convention(c) (
      IDBAudioObjectID, UnsafePointer<IDBAudioObjectPropertyAddress>?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> OSStatus

  /// False unless the process was launched by an armed simulator. Every entry point then calls
  /// straight through to the HAL, and nothing else in this file runs.
  public var armed: Bool
  /// False unless the process was launched armed for output capture. Without it, or `armed`, IO
  /// procs are registered unwrapped.
  public var captureArmed: Bool
  public var createIOProcID: CreateIOProcID
  public var destroyIOProcID: DestroyIOProcID
  public var getPropertyData: GetPropertyData
  public var getPropertyDataSize: GetPropertyDataSize
  public var hasProperty: HasProperty
  public var addPropertyListener: AddPropertyListener
  public var addPropertyListenerBlock: AddPropertyListener
  /// Called on the audio thread, so it may only signal work prepared off it.
  public var startController: @convention(c) () -> Void
  /// Called on the audio thread the first time a capture-armed IO proc renders output.
  public var startCapture: @convention(c) () -> Void

  public init(
    armed: Bool,
    captureArmed: Bool = false,
    createIOProcID: CreateIOProcID,
    destroyIOProcID: DestroyIOProcID,
    getPropertyData: GetPropertyData,
    getPropertyDataSize: GetPropertyDataSize,
    hasProperty: HasProperty,
    addPropertyListener: AddPropertyListener,
    addPropertyListenerBlock: AddPropertyListener,
    startController: @convention(c) () -> Void,
    startCapture: @convention(c) () -> Void = {}
  ) {
    self.armed = armed
    self.captureArmed = captureArmed
    unsafe self.createIOProcID = unsafe createIOProcID
    unsafe self.destroyIOProcID = unsafe destroyIOProcID
    unsafe self.getPropertyData = unsafe getPropertyData
    unsafe self.getPropertyDataSize = unsafe getPropertyDataSize
    unsafe self.hasProperty = unsafe hasProperty
    unsafe self.addPropertyListener = unsafe addPropertyListener
    unsafe self.addPropertyListenerBlock = unsafe addPropertyListenerBlock
    self.startController = startController
    self.startCapture = startCapture
  }
}

private func fourCC(_ code: StaticString) -> UInt32 {
  code.withUTF8Buffer { unsafe $0.reduce(0) { $0 << 8 | UInt32($1) } }
}

private enum Property {
  static let nominalSampleRate = fourCC("nsrt")
  static let defaultInput = fourCC("dIn ")
  static let defaultOutput = fourCC("dOut")
  static let streams = fourCC("stm#")
  static let streamConfiguration = fourCC("slay")
  static let virtualFormat = fourCC("sfmt")
  static let physicalFormat = fourCC("pft ")
  static let direction = fourCC("sdir")
  static let startingChannel = fourCC("stsc")
  static let latency = fourCC("ltnc")
  static let bufferFrameSize = fourCC("fsiz")
  static let globalScope = fourCC("glob")
  static let inputScope = fourCC("inpt")
}

private enum Component {
  static let output = fourCC("auou")
  static let voiceProcessing = fourCC("vpio")
}

private let systemObject: IDBAudioObjectID = 1
private let syntheticCapacityFrames: UInt32 = 4096
private let defaultSyntheticFrames: UInt32 = 512
private let syntheticStreamBase: IDBAudioObjectID = 0x7F00_0000
private let parameterError: OSStatus = -50
private let unknownPropertyError: OSStatus = 0x7768_6F3F // 'who?'
private let defaultSampleRate: Double = 48_000
private let int16ToFloat = 1 / Float(Int16.max)
/// About 1.4 seconds of stereo at 48 kHz, many times the capture client's drain interval.
private let captureSampleCapacity = 1 << 17
private let captureChunkCapacity = 1 << 10

// @unsafe: Raw memory shared with the audio thread, reached only through pointers.
@unsafe private struct IOProcContext {
  let proc: IDBAudioDeviceIOProc
  let clientData: UnsafeMutableRawPointer?
  let device: IDBAudioObjectID
  var ioProcID: UnsafeMutableRawPointer?
  let getPropertyData: AudioHAL.GetPropertyData
  let startController: @convention(c) () -> Void
  /// The device's nominal rate as a bit pattern, read on the client thread and used on the audio thread.
  var sampleRateBits: UInt64 = 0
  var position: Double = 0
  var generation: Int64 = -1
  var started = false
  var finished = false
  var activeCallbacks: UInt64 = 0
  var retired: UInt64 = 0
  var controllerStarted: UInt64 = 0
  let syntheticInput: Bool
  var syntheticListening = false
  let syntheticFrames: UInt32
  let syntheticSamples: UnsafeMutablePointer<Float>
  let syntheticList: UnsafeMutablePointer<AudioBufferList>
  /// Whether injection was armed when the IO proc was created.
  let injecting: Bool
  let startCapture: @convention(c) () -> Void
  /// The output this IO proc renders, while a capture runs. Set at creation, freed only once the
  /// context is retired and no callback can reach it, always under `ioProcLock`.
  var capture: UnsafeMutablePointer<CaptureRing>?
  var captureStarted: UInt64 = 0
  /// The device's nominal rate as a bit pattern, or 0 until the capture client has read it.
  var captureSampleRateBits: UInt64 = 0
  var next: UnsafeMutablePointer<IOProcContext>?
}

private struct CaptureChunkHeader {
  var hostTime: UInt64 = 0
  var sampleTime: Double = 0
  var frames: UInt32 = 0
  var channels: UInt32 = 0
  var discontinuity = false
}

/// One IO proc's rendered output: the audio thread writes and the capture client's thread reads.
/// Each side advances only its own counters, so neither waits for the other; the writer drops a
/// cycle that does not fit rather than overwrite what the reader has not taken.
// @unsafe: Raw memory shared with the audio thread, reached only through pointers.
@unsafe private struct CaptureRing {
  let samples: UnsafeMutablePointer<Float>
  let chunks: UnsafeMutablePointer<CaptureChunkHeader>
  var writtenSamples: UInt64 = 0
  var writtenChunks: UInt64 = 0
  var readSamples: UInt64 = 0
  var readChunks: UInt64 = 0
  /// Set when a cycle is dropped, and carried by the next chunk written.
  var discontinuity: UInt64 = 0

  static func make() -> UnsafeMutablePointer<CaptureRing> {
    let chunks = UnsafeMutablePointer<CaptureChunkHeader>.allocate(capacity: captureChunkCapacity)
    unsafe chunks.initialize(repeating: CaptureChunkHeader(), count: captureChunkCapacity)
    let ring = UnsafeMutablePointer<CaptureRing>.allocate(capacity: 1)
    unsafe ring.initialize(to: CaptureRing(samples: .allocate(capacity: captureSampleCapacity), chunks: chunks))
    return unsafe ring
  }

  static func release(_ ring: UnsafeMutablePointer<CaptureRing>) {
    unsafe ring.pointee.samples.deallocate()
    unsafe ring.pointee.chunks.deinitialize(count: captureChunkCapacity)
    unsafe ring.pointee.chunks.deallocate()
    unsafe ring.deinitialize(count: 1)
    unsafe ring.deallocate()
  }

  static func isEmpty(_ ring: UnsafeMutablePointer<CaptureRing>) -> Bool {
    unsafe IDBAtomicLoad(&ring.pointee.readChunks) == IDBAtomicLoad(&ring.pointee.writtenChunks)
  }
}

// @unsafe: Raw memory shared with the audio thread, reached only through pointers.
@unsafe private struct State {
  /// Guards the installed samples and every context's playback fields. The audio thread only
  /// try-locks it, and skips the fill rather than wait.
  var injectionLock = pthread_mutex_t()
  var samples: UnsafeMutablePointer<Int16>?
  var sampleCount = 0
  var sampleRate = defaultSampleRate
  var generation: Int64 = -1
  var startedGeneration: Int64 = -1
  var finishedGeneration: Int64 = -1
  /// Guards the context lists. Never taken on the audio thread.
  var ioProcLock = pthread_mutex_t()
  var contexts: UnsafeMutablePointer<IOProcContext>?
  /// Destroyed contexts, kept for the life of the process: a callback can hold one as `clientData`
  /// before it has counted itself in, and has to find it retired rather than freed.
  var retired: UnsafeMutablePointer<IOProcContext>?
  /// One entry per read of a synthetic stream's latency, which a client makes only to record. The next
  /// IO proc on that device to be created, or failing that the next to call back, claims the entry and
  /// is the recorder. A playback-only IO proc on a device without input is also given a synthetic
  /// buffer, but claims nothing, so it is never filled or counted as having heard the injection.
  let listening = UnsafeMutablePointer<UInt64>.allocate(capacity: listeningSlots)
  var listeningNext: UInt64 = 0
  /// Voice-processing units alive or being created in the process. Atomic.
  var voiceProcessingUnits: UInt64 = 0
  /// Guards `voiceProcessingInstances`. Never taken on the audio thread.
  var componentLock = pthread_mutex_t()
  /// The created units `voiceProcessingUnits` counts, so only their disposal releases a count.
  var voiceProcessingInstances: [UInt] = []
  /// Whether a capture is running. Atomic; the audio thread only keeps output while it is set.
  var captureActive: UInt64 = 0
  /// Frames the audio thread could not keep during this capture. Atomic.
  var captureDroppedFrames: UInt64 = 0
}

private let listeningSlots = 64

// SAFETY: `State` is guarded by its two locks, apart from the atomics.
// patternlint-disable-next-line swift-nonisolated-unsafe
private nonisolated(unsafe) let state: UnsafeMutablePointer<State> = {
  let state = UnsafeMutablePointer<State>.allocate(capacity: 1)
  unsafe state.initialize(to: State())
  unsafe pthread_mutex_init(&state.pointee.injectionLock, nil)
  unsafe pthread_mutex_init(&state.pointee.ioProcLock, nil)
  unsafe pthread_mutex_init(&state.pointee.componentLock, nil)
  unsafe state.pointee.listening.initialize(repeating: 0, count: listeningSlots)
  return unsafe state
}()

public enum AudioInjectionHAL {
  public static func isSyntheticStream(_ object: IDBAudioObjectID) -> Bool {
    object & 0xFF00_0000 == syntheticStreamBase
  }

  static func deviceSampleRate(_ getPropertyData: AudioHAL.GetPropertyData, device: IDBAudioObjectID) -> Double {
    var rate: Double = 0
    return unsafe read(getPropertyData, device, Property.nominalSampleRate, into: &rate) && rate > 0 ? rate : defaultSampleRate
  }

  /// Answers a property the synthetic input changes, returning false for any other. With `data` nil
  /// it reports only the size.
  public static func syntheticProperty(
    _ hal: AudioHAL,
    object: IDBAudioObjectID,
    address: UnsafePointer<IDBAudioObjectPropertyAddress>?,
    dataSize: UnsafeMutablePointer<UInt32>?,
    data: UnsafeMutableRawPointer?
  ) -> Bool {
    guard let selector = unsafe address?.pointee.selector else {
      return false
    }
    if isSyntheticStream(object) {
      let device = object & ~syntheticStreamBase
      switch selector {
      case Property.virtualFormat, Property.physicalFormat:
        let format = unsafe AudioStreamBasicDescription(
          mSampleRate: deviceSampleRate(hal.getPropertyData, device: device), mFormatID: kAudioFormatLinearPCM,
          mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
          mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        return unsafe answer(format, dataSize, data)
      case Property.direction, Property.startingChannel:
        return unsafe answer(UInt32(1), dataSize, data)
      case Property.latency:
        let answered = unsafe answer(UInt32(0), dataSize, data)
        if answered, unsafe data != nil {
          markListening(device)
        }
        return answered
      default:
        return false
      }
    }
    if object == systemObject, selector == Property.defaultInput, syntheticInputAllowed,
      defaultDevice(hal, Property.defaultInput) == 0
    {
      guard let output = defaultDevice(hal, Property.defaultOutput), output != 0 else {
        return false
      }
      return unsafe answer(output, dataSize, data)
    }
    guard unsafe address?.pointee.scope == Property.inputScope, needsSyntheticInput(hal, object) else {
      return false
    }
    switch selector {
    case Property.streams:
      return unsafe answer(syntheticStreamBase | object, dataSize, data)
    case Property.streamConfiguration:
      let configuration = unsafe AudioBufferList(
        mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil))
      return unsafe answer(configuration, dataSize, data)
    default:
      return false
    }
  }

  public static func createIOProcID(
    _ hal: AudioHAL,
    device: IDBAudioObjectID,
    proc: IDBAudioDeviceIOProc?,
    clientData: UnsafeMutableRawPointer?,
    outIOProcID: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
  ) -> OSStatus {
    guard hal.armed || hal.captureArmed else {
      return unsafe hal.createIOProcID(device, proc, clientData, outIOProcID)
    }
    guard let proc = unsafe proc, let outIOProcID = unsafe outIOProcID else {
      return unsafe proc == nil ? hal.createIOProcID(device, proc, clientData, outIOProcID) : parameterError
    }
    // Creation holds the lock the client thread's sample-rate read does: a HAL property read made
    // while an IO proc is being created disturbs the device.
    unsafe pthread_mutex_lock(&state.pointee.ioProcLock)
    defer { unsafe pthread_mutex_unlock(&state.pointee.ioProcLock) }
    let synthetic = hal.armed && needsSyntheticInput(hal, device)
    var frames: UInt32 = 0
    if synthetic, unsafe !read(hal.getPropertyData, device, Property.bufferFrameSize, into: &frames) {
      frames = 0
    }
    let samples = UnsafeMutablePointer<Float>.allocate(capacity: Int(syntheticCapacityFrames))
    let context = UnsafeMutablePointer<IOProcContext>.allocate(capacity: 1)
    unsafe context.initialize(
      to: IOProcContext(
        proc: proc, clientData: clientData, device: device, getPropertyData: hal.getPropertyData,
        startController: hal.startController, syntheticInput: synthetic,
        syntheticListening: synthetic && claimListening(device),
        syntheticFrames: frames > 0 ? min(frames, syntheticCapacityFrames) : defaultSyntheticFrames,
        syntheticSamples: samples, syntheticList: .allocate(capacity: 1), injecting: hal.armed,
        startCapture: hal.startCapture, capture: hal.captureArmed ? CaptureRing.make() : nil))
    var status = unsafe hal.createIOProcID(device, trampoline, context, outIOProcID)
    if status == noErr, unsafe outIOProcID.pointee == nil {
      status = parameterError
    }
    guard status == noErr else {
      unsafe release(context)
      return status
    }
    unsafe context.pointee.ioProcID = unsafe outIOProcID.pointee
    unsafe context.pointee.next = unsafe state.pointee.contexts
    unsafe state.pointee.contexts = unsafe context
    return noErr
  }

  public static func destroyIOProcID(
    _ hal: AudioHAL, device: IDBAudioObjectID, ioProcID: UnsafeMutableRawPointer?
  ) -> OSStatus {
    guard hal.armed || hal.captureArmed else {
      return unsafe hal.destroyIOProcID(device, ioProcID)
    }
    // Held across the HAL's own destroy, so a concurrent creation cannot be handed the same opaque
    // ID until this one's context is unlinked.
    unsafe pthread_mutex_lock(&state.pointee.ioProcLock)
    let status = unsafe hal.destroyIOProcID(device, ioProcID)
    guard status == noErr else {
      unsafe pthread_mutex_unlock(&state.pointee.ioProcLock)
      return status
    }
    var previous: UnsafeMutablePointer<IOProcContext>?
    var found = unsafe state.pointee.contexts
    while let context = unsafe found, unsafe context.pointee.ioProcID != ioProcID || context.pointee.device != device {
      unsafe previous = unsafe context
      unsafe found = unsafe context.pointee.next
    }
    if let found = unsafe found {
      if let previous = unsafe previous {
        unsafe previous.pointee.next = unsafe found.pointee.next
      } else {
        unsafe state.pointee.contexts = unsafe found.pointee.next
      }
      _ = unsafe IDBAtomicExchange(&found.pointee.retired, 1)
    }
    unsafe pthread_mutex_unlock(&state.pointee.ioProcLock)
    guard let found = unsafe found else {
      return status
    }
    while unsafe IDBAtomicLoad(&found.pointee.activeCallbacks) > 0 {
      sched_yield()
    }
    // Every later callback sees `retired` and returns before it touches the buffers.
    unsafe found.pointee.syntheticSamples.deallocate()
    unsafe found.pointee.syntheticList.deallocate()
    unsafe pthread_mutex_lock(&state.pointee.ioProcLock)
    // Output the capture client has not taken yet waits for its next drain, which frees the ring.
    if let ring = unsafe found.pointee.capture, unsafe CaptureRing.isEmpty(ring) {
      unsafe CaptureRing.release(ring)
      unsafe found.pointee.capture = nil
    }
    unsafe found.pointee.next = unsafe state.pointee.retired
    unsafe state.pointee.retired = unsafe found
    unsafe pthread_mutex_unlock(&state.pointee.ioProcLock)
    return status
  }

  public static func getPropertyData(
    _ hal: AudioHAL,
    object: IDBAudioObjectID,
    address: UnsafePointer<IDBAudioObjectPropertyAddress>?,
    qualifierDataSize: UInt32,
    qualifierData: UnsafeRawPointer?,
    dataSize: UnsafeMutablePointer<UInt32>?,
    data: UnsafeMutableRawPointer?
  ) -> OSStatus {
    guard hal.armed else {
      return unsafe hal.getPropertyData(object, address, qualifierDataSize, qualifierData, dataSize, data)
    }
    if unsafe syntheticProperty(hal, object: object, address: address, dataSize: dataSize, data: data) {
      return noErr
    }
    if isSyntheticStream(object) {
      return unknownPropertyError
    }
    return unsafe hal.getPropertyData(object, address, qualifierDataSize, qualifierData, dataSize, data)
  }

  public static func getPropertyDataSize(
    _ hal: AudioHAL,
    object: IDBAudioObjectID,
    address: UnsafePointer<IDBAudioObjectPropertyAddress>?,
    qualifierDataSize: UInt32,
    qualifierData: UnsafeRawPointer?,
    dataSize: UnsafeMutablePointer<UInt32>?
  ) -> OSStatus {
    guard hal.armed else {
      return unsafe hal.getPropertyDataSize(object, address, qualifierDataSize, qualifierData, dataSize)
    }
    if unsafe syntheticProperty(hal, object: object, address: address, dataSize: dataSize, data: nil) {
      return noErr
    }
    if isSyntheticStream(object) {
      return unknownPropertyError
    }
    return unsafe hal.getPropertyDataSize(object, address, qualifierDataSize, qualifierData, dataSize)
  }

  public static func hasProperty(
    _ hal: AudioHAL, object: IDBAudioObjectID, address: UnsafePointer<IDBAudioObjectPropertyAddress>?
  ) -> Bool {
    guard hal.armed else {
      return unsafe hal.hasProperty(object, address)
    }
    var size: UInt32 = 0
    return unsafe syntheticProperty(hal, object: object, address: address, dataSize: &size, data: nil)
      || (!isSyntheticStream(object) && hal.hasProperty(object, address))
  }

  public static func addPropertyListener(
    _ hal: AudioHAL,
    object: IDBAudioObjectID,
    address: UnsafePointer<IDBAudioObjectPropertyAddress>?,
    listener: UnsafeMutableRawPointer?,
    clientData: UnsafeMutableRawPointer?
  ) -> OSStatus {
    guard hal.armed else {
      return unsafe hal.addPropertyListener(object, address, listener, clientData)
    }
    return unsafe isSyntheticStream(object) ? noErr : hal.addPropertyListener(object, address, listener, clientData)
  }

  public static func addPropertyListenerBlock(
    _ hal: AudioHAL,
    object: IDBAudioObjectID,
    address: UnsafePointer<IDBAudioObjectPropertyAddress>?,
    queue: UnsafeMutableRawPointer?,
    listener: UnsafeMutableRawPointer?
  ) -> OSStatus {
    guard hal.armed else {
      return unsafe hal.addPropertyListenerBlock(object, address, queue, listener)
    }
    return unsafe isSyntheticStream(object) ? noErr : hal.addPropertyListenerBlock(object, address, queue, listener)
  }

  /// Called before an audio component instance is created. Returns whether it is a voice-processing
  /// unit, counted from now on: creating one can already read the default devices.
  public static func willCreateComponentInstance(_ hal: AudioHAL, description: IDBAudioComponentDescription?) -> Bool {
    guard hal.armed, let description, isVoiceProcessing(description) else {
      return false
    }
    _ = unsafe IDBAtomicAdd(&state.pointee.voiceProcessingUnits, 1)
    return true
  }

  /// Called once the creation `willCreateComponentInstance` was told of has finished.
  public static func didCreateComponentInstance(counted: Bool, instance: UnsafeMutableRawPointer?, status: OSStatus) {
    guard counted else {
      return
    }
    guard status == noErr, let instance = unsafe instance else {
      _ = unsafe IDBAtomicAdd(&state.pointee.voiceProcessingUnits, -1)
      return
    }
    unsafe pthread_mutex_lock(&state.pointee.componentLock)
    unsafe state.pointee.voiceProcessingInstances.append(UInt(bitPattern: instance))
    unsafe pthread_mutex_unlock(&state.pointee.componentLock)
  }

  /// Disposes of an audio component instance through `dispose`, releasing its count if it has one.
  public static func disposeComponentInstance(
    _ hal: AudioHAL, instance: UnsafeMutableRawPointer?, dispose: () -> OSStatus
  ) -> OSStatus {
    guard hal.armed, let instance = unsafe instance else {
      return dispose()
    }
    let status = dispose()
    guard status == noErr else {
      return status
    }
    // A unit created at the same address meanwhile adds its own entry, so removing either keeps the count.
    unsafe pthread_mutex_lock(&state.pointee.componentLock)
    if let index = unsafe state.pointee.voiceProcessingInstances.firstIndex(of: UInt(bitPattern: instance)) {
      unsafe state.pointee.voiceProcessingInstances.remove(at: index)
      _ = unsafe IDBAtomicAdd(&state.pointee.voiceProcessingUnits, -1)
    }
    unsafe pthread_mutex_unlock(&state.pointee.componentLock)
    return status
  }

  private static func isVoiceProcessing(_ description: IDBAudioComponentDescription) -> Bool {
    description.type == Component.output && description.subType == Component.voiceProcessing
  }

  /// A voice-processing unit has the audio server aggregate the default input and output devices.
  /// The server builds that aggregate without the synthetic input this process sees, and an
  /// input-scope property set on it then never returns, so CoreAudio aborts the process. While such
  /// a unit exists the host's own topology is reported instead.
  private static var syntheticInputAllowed: Bool {
    unsafe IDBAtomicLoad(&state.pointee.voiceProcessingUnits) == 0
  }

  private static func release(_ context: UnsafeMutablePointer<IOProcContext>) {
    unsafe context.pointee.syntheticSamples.deallocate()
    unsafe context.pointee.syntheticList.deallocate()
    unsafe context.pointee.capture.map(CaptureRing.release)
    unsafe context.deinitialize(count: 1)
    unsafe context.deallocate()
  }

  private static func read<Value>(
    _ getPropertyData: AudioHAL.GetPropertyData, _ object: IDBAudioObjectID, _ selector: UInt32,
    into value: inout Value
  ) -> Bool {
    var address = IDBAudioObjectPropertyAddress(selector: selector, scope: Property.globalScope, element: 0)
    var size = UInt32(MemoryLayout<Value>.size)
    return withUnsafeMutableBytes(of: &value) { unsafe getPropertyData(object, &address, 0, nil, &size, $0.baseAddress) } == noErr
  }

  /// Nil when the read fails, which is not the same as a host with no such device.
  private static func defaultDevice(_ hal: AudioHAL, _ selector: UInt32) -> IDBAudioObjectID? {
    var device: IDBAudioObjectID = 0
    return unsafe read(hal.getPropertyData, systemObject, selector, into: &device) ? device : nil
  }

  private static func needsSyntheticInput(_ hal: AudioHAL, _ device: IDBAudioObjectID) -> Bool {
    guard syntheticInputAllowed, device != systemObject, !isSyntheticStream(device), defaultDevice(hal, Property.defaultInput) == 0 else {
      return false
    }
    var address = IDBAudioObjectPropertyAddress(selector: Property.streams, scope: Property.inputScope, element: 0)
    var size: UInt32 = 0
    return unsafe hal.getPropertyDataSize(device, &address, 0, nil, &size) == noErr && size == 0
  }

  private static func answer<Value>(
    _ value: Value, _ dataSize: UnsafeMutablePointer<UInt32>?, _ data: UnsafeMutableRawPointer?
  ) -> Bool {
    let size = UInt32(MemoryLayout<Value>.size)
    guard let dataSize = unsafe dataSize, unsafe data == nil || dataSize.pointee >= size else {
      return false
    }
    unsafe data?.storeBytes(of: value, as: Value.self)
    unsafe dataSize.pointee = size
    return true
  }

  private static func markListening(_ device: IDBAudioObjectID) {
    // A free slot is reserved, so an unclaimed mark is never overwritten while one remains. Only with
    // every slot holding an unclaimed mark is the oldest-written one replaced.
    if (0..<listeningSlots).contains(where: { unsafe IDBAtomicCompareExchange(state.pointee.listening + $0, 0, UInt64(device)) }) {
      return
    }
    let slot = unsafe Int(IDBAtomicAdd(&state.pointee.listeningNext, 1) % UInt64(listeningSlots))
    _ = unsafe IDBAtomicExchange(state.pointee.listening + slot, UInt64(device))
  }
}

/// Lock-free, because the audio thread claims too.
private func claimListening(_ device: IDBAudioObjectID) -> Bool {
  (0..<listeningSlots).contains { unsafe IDBAtomicCompareExchange(state.pointee.listening + $0, UInt64(device), 0) }
}

private func frameCapacity(_ buffer: AudioBuffer) -> UInt32 {
  unsafe buffer.mData == nil ? 0 : buffer.mDataByteSize / UInt32(MemoryLayout<Float>.size) / max(buffer.mNumberChannels, 1)
}

private func fill(_ list: UnsafeMutablePointer<AudioBufferList>, deviceRate: Double, _ context: UnsafeMutablePointer<IOProcContext>) {
  guard unsafe pthread_mutex_trylock(&state.pointee.injectionLock) == 0 else {
    return
  }
  defer { unsafe pthread_mutex_unlock(&state.pointee.injectionLock) }
  guard let samples = unsafe state.pointee.samples else {
    return
  }
  let buffers = unsafe UnsafeMutableAudioBufferListPointer(list)
  var frames = UInt32.max
  // swift-format would join `for unsafe` into one word.
  // swift-format-ignore
  for unsafe buffer in buffers where unsafe frameCapacity(buffer) > 0 {
    frames = unsafe min(frames, frameCapacity(buffer))
  }
  guard frames != .max else {
    return
  }
  if unsafe context.pointee.generation != state.pointee.generation {
    unsafe context.pointee.generation = unsafe state.pointee.generation
    unsafe context.pointee.position = 0
    unsafe context.pointee.started = false
    unsafe context.pointee.finished = false
  }
  guard deviceRate > 0 else {
    return
  }

  // Each buffer is one channel group of the same frames, so each starts from the same position.
  let step = unsafe state.pointee.sampleRate / deviceRate
  var position = unsafe context.pointee.position
  // swift-format would join `for unsafe` into one word.
  // swift-format-ignore
  for unsafe buffer in buffers {
    guard let data = unsafe buffer.mData, unsafe frameCapacity(buffer) > 0 else {
      continue
    }
    let channels = unsafe Int(max(buffer.mNumberChannels, 1))
    let output = unsafe data.assumingMemoryBound(to: Float.self)
    position = unsafe context.pointee.position
    for frame in 0..<Int(frames) {
      let index = Int(position)
      let value = unsafe index < state.pointee.sampleCount ? Float(samples[index]) * int16ToFloat : 0
      for channel in 0..<channels {
        unsafe output[frame * channels + channel] = value
      }
      position += step
    }
  }

  unsafe context.pointee.position = position
  unsafe context.pointee.started = true
  unsafe state.pointee.startedGeneration = unsafe state.pointee.generation
  if unsafe position >= Double(state.pointee.sampleCount) {
    unsafe context.pointee.finished = true
    unsafe state.pointee.finishedGeneration = unsafe state.pointee.generation
  }
}

private func trampoline(
  device: IDBAudioObjectID,
  now: UnsafePointer<AudioTimeStamp>?,
  inputData: UnsafePointer<AudioBufferList>?,
  inputTime: UnsafePointer<AudioTimeStamp>?,
  outputData: UnsafeMutablePointer<AudioBufferList>?,
  outputTime: UnsafePointer<AudioTimeStamp>?,
  clientData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let context = unsafe clientData?.assumingMemoryBound(to: IOProcContext.self) else {
    return noErr
  }
  // Counted before `retired` is read, so a destroy either waits for this callback or this callback
  // sees `retired` and leaves. Lock-free, because this is the audio thread.
  _ = unsafe IDBAtomicAdd(&context.pointee.activeCallbacks, 1)
  defer { _ = unsafe IDBAtomicAdd(&context.pointee.activeCallbacks, -1) }
  guard unsafe IDBAtomicLoad(&context.pointee.retired) == 0 else {
    return noErr
  }

  var input = unsafe UnsafeMutablePointer(mutating: inputData)
  var listening = unsafe context.pointee.injecting
  if unsafe context.pointee.syntheticInput, unsafe (input?.pointee.mNumberBuffers ?? 0) == 0 {
    if unsafe !context.pointee.syntheticListening {
      unsafe context.pointee.syntheticListening = claimListening(device)
    }
    listening = unsafe context.pointee.syntheticListening
    // AudioToolbox drops an input buffer that is not exactly one IO cycle, which the output buffer is.
    let outputFrames = unsafe outputData.map { unsafe $0.pointee.mNumberBuffers > 0 ? frameCapacity($0.pointee.mBuffers) : 0 } ?? 0
    let frames = unsafe outputFrames > 0 ? min(outputFrames, syntheticCapacityFrames) : context.pointee.syntheticFrames
    unsafe context.pointee.syntheticSamples.update(repeating: 0, count: Int(frames))
    unsafe context.pointee.syntheticList.pointee = unsafe AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: 1, mDataByteSize: frames * UInt32(MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(context.pointee.syntheticSamples)))
    unsafe input = unsafe context.pointee.syntheticList
  }
  if listening, let input = unsafe input, unsafe input.pointee.mNumberBuffers > 0 {
    if unsafe IDBAtomicExchange(&context.pointee.controllerStarted, 1) == 0 {
      unsafe context.pointee.startController()
    }
    let rate = unsafe Double(bitPattern: IDBAtomicLoad(&context.pointee.sampleRateBits))
    unsafe fill(input, deviceRate: rate, context)
  }
  let status = unsafe context.pointee.proc(device, now, input, inputTime, outputData, outputTime, context.pointee.clientData)
  if let ring = unsafe context.pointee.capture {
    unsafe keep(outputData, at: outputTime, in: ring, context)
  }
  return status
}

/// Copies what the app rendered into the ring, on the audio thread: no lock, no allocation.
private func keep(
  _ output: UnsafeMutablePointer<AudioBufferList>?, at time: UnsafePointer<AudioTimeStamp>?,
  in ring: UnsafeMutablePointer<CaptureRing>, _ context: UnsafeMutablePointer<IOProcContext>
) {
  guard let output = unsafe output, unsafe output.pointee.mNumberBuffers > 0 else {
    return
  }
  if unsafe IDBAtomicExchange(&context.pointee.captureStarted, 1) == 0 {
    unsafe context.pointee.startCapture()
  }
  guard unsafe IDBAtomicLoad(&state.pointee.captureActive) != 0 else {
    return
  }
  let buffers = unsafe UnsafeMutableAudioBufferListPointer(output)
  var frames = UInt32.max
  var channels: UInt32 = 0
  // swift-format would join `for unsafe` into one word.
  // swift-format-ignore
  for unsafe buffer in buffers where unsafe frameCapacity(buffer) > 0 {
    frames = unsafe min(frames, frameCapacity(buffer))
    unsafe channels += max(buffer.mNumberChannels, 1)
  }
  guard frames != .max, Int(channels) <= AudioCaptureFile.maximumChannels, Int(frames) <= AudioCaptureFile.maximumFrames
  else {
    return
  }
  let count = UInt64(frames) * UInt64(channels)
  let written = unsafe IDBAtomicLoad(&ring.pointee.writtenSamples)
  let chunk = unsafe IDBAtomicLoad(&ring.pointee.writtenChunks)
  guard unsafe written - IDBAtomicLoad(&ring.pointee.readSamples) + count <= UInt64(captureSampleCapacity),
    unsafe chunk - IDBAtomicLoad(&ring.pointee.readChunks) < UInt64(captureChunkCapacity)
  else {
    _ = unsafe IDBAtomicAdd(&state.pointee.captureDroppedFrames, Int64(frames))
    _ = unsafe IDBAtomicExchange(&ring.pointee.discontinuity, 1)
    return
  }
  let mask = UInt64(captureSampleCapacity - 1)
  var index = written
  for frame in 0..<Int(frames) {
    // swift-format would join `for unsafe` into one word.
    // swift-format-ignore
    for unsafe buffer in buffers where unsafe frameCapacity(buffer) > 0 {
      guard let data = unsafe buffer.mData?.assumingMemoryBound(to: Float.self) else {
        continue
      }
      let bufferChannels = unsafe Int(max(buffer.mNumberChannels, 1))
      for channel in 0..<bufferChannels {
        unsafe ring.pointee.samples[Int(index & mask)] = unsafe data[frame * bufferChannels + channel]
        index += 1
      }
    }
  }
  let flags = unsafe time?.pointee.mFlags ?? []
  unsafe ring.pointee.chunks[Int(chunk & UInt64(captureChunkCapacity - 1))] = unsafe CaptureChunkHeader(
    hostTime: flags.contains(.hostTimeValid) ? time?.pointee.mHostTime ?? 0 : 0,
    sampleTime: flags.contains(.sampleTimeValid) ? time?.pointee.mSampleTime ?? 0 : 0,
    frames: frames, channels: channels,
    discontinuity: IDBAtomicExchange(&ring.pointee.discontinuity, 0) != 0)
  // Published after the samples and header, which the reader only touches once it sees the count.
  _ = unsafe IDBAtomicExchange(&ring.pointee.writtenSamples, index)
  _ = unsafe IDBAtomicExchange(&ring.pointee.writtenChunks, chunk + 1)
}

/// What a capture-armed process renders, kept from `begin` to `end` and handed to the capture
/// client's thread. Every function here runs on that thread.
enum AudioCaptureHAL {
  static func begin() {
    unsafe pthread_mutex_lock(&state.pointee.ioProcLock)
    defer { unsafe pthread_mutex_unlock(&state.pointee.ioProcLock) }
    // Nothing is written while no capture runs, so moving each reader up to its writer discards
    // what an earlier capture left without racing the audio thread.
    var context = unsafe state.pointee.contexts
    while let current = unsafe context {
      if let ring = unsafe current.pointee.capture {
        _ = unsafe IDBAtomicExchange(&ring.pointee.readSamples, IDBAtomicLoad(&ring.pointee.writtenSamples))
        _ = unsafe IDBAtomicExchange(&ring.pointee.readChunks, IDBAtomicLoad(&ring.pointee.writtenChunks))
        _ = unsafe IDBAtomicExchange(&ring.pointee.discontinuity, 0)
      }
      unsafe context = unsafe current.pointee.next
    }
    releaseRetiredRings()
    _ = unsafe IDBAtomicExchange(&state.pointee.captureDroppedFrames, 0)
    _ = unsafe IDBAtomicExchange(&state.pointee.captureActive, 1)
  }

  static func drain(_ body: (AudioCaptureChunk) -> Void) -> UInt64 {
    var drained: [AudioCaptureChunk] = []
    unsafe pthread_mutex_lock(&state.pointee.ioProcLock)
    var context = unsafe state.pointee.contexts
    while let current = unsafe context {
      if let ring = unsafe current.pointee.capture {
        // Under `ioProcLock`, as every HAL read the shim makes is: never beside an IO proc's creation.
        if unsafe IDBAtomicLoad(&current.pointee.captureSampleRateBits) == 0 {
          var rate: Double = 0
          var address = IDBAudioObjectPropertyAddress(
            selector: Property.nominalSampleRate, scope: Property.globalScope, element: 0)
          var size = UInt32(MemoryLayout<Double>.size)
          if unsafe current.pointee.getPropertyData(current.pointee.device, &address, 0, nil, &size, &rate) == noErr, rate > 0 {
            _ = unsafe IDBAtomicExchange(&current.pointee.captureSampleRateBits, rate.bitPattern)
          }
        }
        unsafe take(from: ring, of: current, into: &drained)
      }
      unsafe context = unsafe current.pointee.next
    }
    var retired = unsafe state.pointee.retired
    while let current = unsafe retired {
      if let ring = unsafe current.pointee.capture {
        unsafe take(from: ring, of: current, into: &drained)
        unsafe CaptureRing.release(ring)
        unsafe current.pointee.capture = nil
      }
      unsafe retired = unsafe current.pointee.next
    }
    unsafe pthread_mutex_unlock(&state.pointee.ioProcLock)
    drained.forEach(body)
    return unsafe IDBAtomicLoad(&state.pointee.captureDroppedFrames)
  }

  static func end() {
    _ = unsafe IDBAtomicExchange(&state.pointee.captureActive, 0)
    unsafe pthread_mutex_lock(&state.pointee.ioProcLock)
    defer { unsafe pthread_mutex_unlock(&state.pointee.ioProcLock) }
    // A callback counts itself in before it reads `captureActive`, so once each IO proc has been
    // seen idle, no callback that saw the capture running is still writing.
    var context = unsafe state.pointee.contexts
    while let current = unsafe context {
      while unsafe IDBAtomicLoad(&current.pointee.activeCallbacks) > 0 {
        sched_yield()
      }
      unsafe context = unsafe current.pointee.next
    }
  }

  private static func take(
    from ring: UnsafeMutablePointer<CaptureRing>, of context: UnsafeMutablePointer<IOProcContext>,
    into drained: inout [AudioCaptureChunk]
  ) {
    let writtenChunks = unsafe IDBAtomicLoad(&ring.pointee.writtenChunks)
    var readChunks = unsafe IDBAtomicLoad(&ring.pointee.readChunks)
    var readSamples = unsafe IDBAtomicLoad(&ring.pointee.readSamples)
    let mask = UInt64(captureSampleCapacity - 1)
    let rate = unsafe Double(bitPattern: IDBAtomicLoad(&context.pointee.captureSampleRateBits))
    while readChunks < writtenChunks {
      let header = unsafe ring.pointee.chunks[Int(readChunks & UInt64(captureChunkCapacity - 1))]
      let count = Int(header.frames) * Int(header.channels)
      var samples = [Float](repeating: 0, count: count)
      for index in 0..<count {
        samples[index] = unsafe ring.pointee.samples[Int((readSamples + UInt64(index)) & mask)]
      }
      unsafe drained.append(
        AudioCaptureChunk(
          stream: UInt64(UInt(bitPattern: context)), device: context.pointee.device, sampleRate: rate,
          hostTime: header.hostTime, sampleTime: header.sampleTime, channels: Int(header.channels),
          discontinuity: header.discontinuity, samples: samples))
      readSamples += UInt64(count)
      readChunks += 1
    }
    _ = unsafe IDBAtomicExchange(&ring.pointee.readSamples, readSamples)
    _ = unsafe IDBAtomicExchange(&ring.pointee.readChunks, readChunks)
  }

  private static func releaseRetiredRings() {
    var retired = unsafe state.pointee.retired
    while let current = unsafe retired {
      if let ring = unsafe current.pointee.capture {
        unsafe CaptureRing.release(ring)
        unsafe current.pointee.capture = nil
      }
      unsafe retired = unsafe current.pointee.next
    }
  }
}

public struct HALAudioCaptureEngine: AudioCaptureEngine {
  public init() {}

  public func begin() {
    AudioCaptureHAL.begin()
  }

  public func drain(_ body: (AudioCaptureChunk) -> Void) -> UInt64 {
    AudioCaptureHAL.drain(body)
  }

  public func end() {
    AudioCaptureHAL.end()
  }
}

public struct HALAudioInjectionEngine: AudioInjectionEngine {
  public init() {}

  public func replace(samples: [Int16], sampleRate: Double, generation: Int64) {
    let copy = UnsafeMutablePointer<Int16>.allocate(capacity: samples.count)
    unsafe copy.initialize(from: samples, count: samples.count)
    unsafe install(copy, count: samples.count, sampleRate: sampleRate, generation: generation)
  }

  public func clear() {
    unsafe install(nil, count: 0, sampleRate: defaultSampleRate, generation: -1)
  }

  private func install(_ samples: UnsafeMutablePointer<Int16>?, count: Int, sampleRate: Double, generation: Int64) {
    unsafe pthread_mutex_lock(&state.pointee.injectionLock)
    let previous = unsafe state.pointee.samples
    unsafe state.pointee.samples = unsafe samples
    unsafe state.pointee.sampleCount = count
    unsafe state.pointee.sampleRate = sampleRate
    unsafe state.pointee.generation = generation
    unsafe state.pointee.startedGeneration = -1
    unsafe state.pointee.finishedGeneration = -1
    unsafe pthread_mutex_unlock(&state.pointee.injectionLock)
    unsafe previous?.deallocate()
  }

  public func pollProgress() -> AudioInjectionProgress {
    unsafe pthread_mutex_lock(&state.pointee.ioProcLock)
    var context = unsafe state.pointee.contexts
    while let current = unsafe context {
      if unsafe IDBAtomicLoad(&current.pointee.sampleRateBits) == 0 {
        let rate = unsafe AudioInjectionHAL.deviceSampleRate(current.pointee.getPropertyData, device: current.pointee.device)
        _ = unsafe IDBAtomicExchange(&current.pointee.sampleRateBits, rate.bitPattern)
      }
      unsafe context = unsafe current.pointee.next
    }

    unsafe pthread_mutex_lock(&state.pointee.injectionLock)
    let generation = unsafe state.pointee.generation
    let started = unsafe generation >= 0 && state.pointee.startedGeneration == generation
    var anyUnfinished = false
    unsafe context = unsafe state.pointee.contexts
    while let current = unsafe context {
      anyUnfinished =
        unsafe anyUnfinished
        || (current.pointee.generation == generation && !current.pointee.finished)
      unsafe context = unsafe current.pointee.next
    }
    // Freeing the samples ends playback but keeps the generation markers, so later polls for this
    // generation still report it finished.
    let finished =
      unsafe started && state.pointee.finishedGeneration == generation && (state.pointee.samples == nil || !anyUnfinished)
    let played = unsafe finished ? state.pointee.samples : nil
    if unsafe played != nil {
      unsafe state.pointee.samples = nil
      unsafe state.pointee.sampleCount = 0
    }
    unsafe pthread_mutex_unlock(&state.pointee.injectionLock)
    unsafe pthread_mutex_unlock(&state.pointee.ioProcLock)
    unsafe played?.deallocate()
    return AudioInjectionProgress(generation: generation, started: started, finished: finished)
  }
}
