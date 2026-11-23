/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
@_implementationOnly import ShimulatorAudioInjectionCore
@_implementationOnly import ShimulatorAudioInjectionHAL
@_implementationOnly import ShimulatorAudioInjectionPrivate
@_implementationOnly import ShimulatorProtocol
import os

/// Prepared off the audio thread and signalled from it: the IO proc may not start a thread itself.
private let controllerStart: any DispatchSourceUserDataOr = {
  let source = DispatchSource.makeUserDataOrSource(queue: .global(qos: .utility))
  source.setEventHandler {
    controllerStart.cancel()
    startClient()
  }
  source.activate()
  return source
}()

private let captureStart: any DispatchSourceUserDataOr = {
  let source = DispatchSource.makeUserDataOrSource(queue: .global(qos: .utility))
  source.setEventHandler {
    captureStart.cancel()
    startCaptureClient()
  }
  source.activate()
  return source
}()

private let realHAL = unsafe AudioHAL(
  armed: IDBAudioInjectionIsArmed(),
  captureArmed: IDBAudioCaptureIsArmed(),
  createIOProcID: AudioDeviceCreateIOProcID,
  destroyIOProcID: AudioDeviceDestroyIOProcID,
  getPropertyData: AudioObjectGetPropertyData,
  getPropertyDataSize: AudioObjectGetPropertyDataSize,
  hasProperty: { object, address in unsafe AudioObjectHasProperty(object, address) },
  addPropertyListener: unsafe AudioObjectAddPropertyListener,
  addPropertyListenerBlock: unsafe AudioObjectAddPropertyListenerBlock,
  startController: { controllerStart.or(data: 1) },
  startCapture: { captureStart.or(data: 1) })

private func startClient() {
  let logger = Logger(subsystem: "com.facebook.idb", category: "audio-injection")
  guard let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"], !udid.isEmpty else {
    logger.error("No simulator UDID is available to find the audio socket")
    return
  }
  let path = ShimulatorWireProtocol.socketPath(capability: ShimulatorAudioInjection.capability, simulatorUDID: udid)
  Thread.detachNewThread {
    ShimulatorClient(
      socketPath: path,
      handler: AudioInjectionController(engine: HALAudioInjectionEngine()),
      log: { message in logger.log("\(message, privacy: .public)") }
    ).run()
  }
}

private func startCaptureClient() {
  let logger = Logger(subsystem: "com.facebook.idb", category: "audio-capture")
  guard let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"], !udid.isEmpty else {
    logger.error("No simulator UDID is available to find the audio capture socket")
    return
  }
  let path = ShimulatorWireProtocol.socketPath(capability: ShimulatorAudioCapture.capability, simulatorUDID: udid)
  Thread.detachNewThread {
    ShimulatorClient(
      socketPath: path,
      handler: AudioCaptureController(engine: HALAudioCaptureEngine()),
      log: { message in logger.log("\(message, privacy: .public)") }
    ).run()
  }
}

// Calls from this image to the originals are not interposed, so they reach CoreAudio.
// `@_cdecl`, not `@c @implementation`: the open-source build supports Swift 6.2.

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioDeviceCreateIOProcID")
func IDBAudioDeviceCreateIOProcID(
  _ device: IDBAudioObjectID,
  _ proc: IDBAudioDeviceIOProc?,
  _ clientData: UnsafeMutableRawPointer?,
  _ outIOProcID: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> OSStatus {
  if realHAL.armed {
    _ = controllerStart
  }
  if realHAL.captureArmed {
    _ = captureStart
  }
  return unsafe AudioInjectionHAL.createIOProcID(
    realHAL, device: device, proc: proc, clientData: clientData, outIOProcID: outIOProcID)
}

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioDeviceDestroyIOProcID")
func IDBAudioDeviceDestroyIOProcID(_ device: IDBAudioObjectID, _ ioProcID: UnsafeMutableRawPointer?) -> OSStatus {
  unsafe AudioInjectionHAL.destroyIOProcID(realHAL, device: device, ioProcID: ioProcID)
}

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioObjectGetPropertyData")
func IDBAudioObjectGetPropertyData(
  _ object: IDBAudioObjectID,
  _ address: UnsafePointer<IDBAudioObjectPropertyAddress>?,
  _ qualifierDataSize: UInt32,
  _ qualifierData: UnsafeRawPointer?,
  _ dataSize: UnsafeMutablePointer<UInt32>?,
  _ data: UnsafeMutableRawPointer?
) -> OSStatus {
  unsafe AudioInjectionHAL.getPropertyData(
    realHAL, object: object, address: address, qualifierDataSize: qualifierDataSize, qualifierData: qualifierData,
    dataSize: dataSize, data: data)
}

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioObjectGetPropertyDataSize")
func IDBAudioObjectGetPropertyDataSize(
  _ object: IDBAudioObjectID,
  _ address: UnsafePointer<IDBAudioObjectPropertyAddress>?,
  _ qualifierDataSize: UInt32,
  _ qualifierData: UnsafeRawPointer?,
  _ dataSize: UnsafeMutablePointer<UInt32>?
) -> OSStatus {
  unsafe AudioInjectionHAL.getPropertyDataSize(
    realHAL, object: object, address: address, qualifierDataSize: qualifierDataSize, qualifierData: qualifierData,
    dataSize: dataSize)
}

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioObjectHasProperty")
func IDBAudioObjectHasProperty(_ object: IDBAudioObjectID, _ address: UnsafePointer<IDBAudioObjectPropertyAddress>?) -> Bool {
  unsafe AudioInjectionHAL.hasProperty(realHAL, object: object, address: address)
}

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioObjectAddPropertyListener")
func IDBAudioObjectAddPropertyListener(
  _ object: IDBAudioObjectID,
  _ address: UnsafePointer<IDBAudioObjectPropertyAddress>?,
  _ listener: UnsafeMutableRawPointer?,
  _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
  unsafe AudioInjectionHAL.addPropertyListener(
    realHAL, object: object, address: address, listener: listener, clientData: clientData)
}

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioObjectAddPropertyListenerBlock")
func IDBAudioObjectAddPropertyListenerBlock(
  _ object: IDBAudioObjectID,
  _ address: UnsafePointer<IDBAudioObjectPropertyAddress>?,
  _ queue: UnsafeMutableRawPointer?,
  _ listener: UnsafeMutableRawPointer?
) -> OSStatus {
  unsafe AudioInjectionHAL.addPropertyListenerBlock(realHAL, object: object, address: address, queue: queue, listener: listener)
}

private func componentDescription(_ component: UnsafeMutableRawPointer?) -> IDBAudioComponentDescription? {
  var description = IDBAudioComponentDescription()
  guard realHAL.armed, let component = unsafe component, unsafe AudioComponentGetDescription(component, &description) == noErr else {
    return nil
  }
  return description
}

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioComponentInstanceNew")
func IDBAudioComponentInstanceNew(
  _ component: UnsafeMutableRawPointer?, _ outInstance: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> OSStatus {
  let counted = unsafe AudioInjectionHAL.willCreateComponentInstance(realHAL, description: componentDescription(component))
  let status = unsafe AudioComponentInstanceNew(component, outInstance)
  unsafe AudioInjectionHAL.didCreateComponentInstance(counted: counted, instance: outInstance?.pointee, status: status)
  return status
}

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioComponentInstantiate")
func IDBAudioComponentInstantiate(
  _ component: UnsafeMutableRawPointer?, _ options: UInt32,
  _ completionHandler: @escaping @convention(block) (UnsafeMutableRawPointer?, OSStatus) -> Void
) {
  let counted = unsafe AudioInjectionHAL.willCreateComponentInstance(realHAL, description: componentDescription(component))
  unsafe AudioComponentInstantiate(component, options) { instance, status in
    unsafe AudioInjectionHAL.didCreateComponentInstance(counted: counted, instance: instance, status: status)
    unsafe completionHandler(instance, status)
  }
}

// patternlint-disable-next-line cdecl-unsupported
@_cdecl("IDBAudioComponentInstanceDispose")
func IDBAudioComponentInstanceDispose(_ instance: UnsafeMutableRawPointer?) -> OSStatus {
  unsafe AudioInjectionHAL.disposeComponentInstance(realHAL, instance: instance) {
    unsafe AudioComponentInstanceDispose(instance)
  }
}
