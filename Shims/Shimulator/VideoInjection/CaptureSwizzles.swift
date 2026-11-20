/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
@_implementationOnly import ShimulatorVideoInjectionAVFoundation

/// Each `shimulator_` method replaces the AVFoundation method named beside it; calling itself reaches the original.
/// A session holding the virtual input, or no native input yet, is driven by the shim; any other is passed through.
func installSwizzles() {
  let device: AnyClass? = object_getClass(AVCaptureDevice.self)
  let session = AVCaptureSession.self
  let swizzles: [(AnyClass?, String, Selector)] = [
    (device, "defaultDeviceWithMediaType:", #selector(AVCaptureDevice.shimulator_defaultDevice(for:))),
    (device, "defaultDeviceWithDeviceType:mediaType:position:", #selector(AVCaptureDevice.shimulator_defaultDevice(_:for:position:))),
    (device, "devicesWithMediaType:", #selector(AVCaptureDevice.shimulator_devices(for:))),
    (device, "devices", #selector(AVCaptureDevice.shimulator_devices as () -> [AVCaptureDevice])),
    (device, "deviceWithUniqueID:", #selector(AVCaptureDevice.shimulator_device(uniqueID:))),
    (device, "systemPreferredCamera", #selector(getter: AVCaptureDevice.shimulator_systemPreferredCamera)),
    (device, "userPreferredCamera", #selector(getter: AVCaptureDevice.shimulator_userPreferredCamera)),
    (device, "authorizationStatusForMediaType:", #selector(AVCaptureDevice.shimulator_authorizationStatus(for:))),
    (device, "requestAccessForMediaType:completionHandler:", #selector(AVCaptureDevice.shimulator_requestAccess(for:completionHandler:))),
    (
      object_getClass(AVCaptureDevice.DiscoverySession.self), "discoverySessionWithDeviceTypes:mediaType:position:",
      #selector(AVCaptureDevice.DiscoverySession.shimulator_discoverySession(deviceTypes:mediaType:position:))
    ),
    (AVCaptureDeviceInput.self, "initWithDevice:error:", NSSelectorFromString("initShimulatorWithDevice:error:")),
    (AVCaptureOutput.self, "connections", #selector(getter: AVCaptureOutput.shimulator_connections)),
    (AVCaptureOutput.self, "connectionWithMediaType:", #selector(AVCaptureOutput.shimulator_connection(with:))),
    (session, "canAddInput:", #selector(AVCaptureSession.shimulator_canAddInput(_:))),
    (session, "addInput:", #selector(AVCaptureSession.shimulator_addInput(_:))),
    (session, "removeInput:", #selector(AVCaptureSession.shimulator_removeInput(_:))),
    (session, "inputs", #selector(getter: AVCaptureSession.shimulator_inputs)),
    (session, "canAddOutput:", #selector(AVCaptureSession.shimulator_canAddOutput(_:))),
    (session, "addOutput:", #selector(AVCaptureSession.shimulator_addOutput(_:))),
    (session, "removeOutput:", #selector(AVCaptureSession.shimulator_removeOutput(_:))),
    (session, "outputs", #selector(getter: AVCaptureSession.shimulator_outputs)),
    (session, "connections", #selector(getter: AVCaptureSession.shimulator_connections)),
    (session, "canSetSessionPreset:", #selector(AVCaptureSession.shimulator_canSetSessionPreset(_:))),
    (session, "setSessionPreset:", #selector(setter: AVCaptureSession.shimulator_sessionPreset)),
    (session, "sessionPreset", #selector(getter: AVCaptureSession.shimulator_sessionPreset)),
    (session, "startRunning", #selector(AVCaptureSession.shimulator_startRunning)),
    (session, "stopRunning", #selector(AVCaptureSession.shimulator_stopRunning)),
    (session, "isRunning", #selector(getter: AVCaptureSession.shimulator_isRunning)),
    (session, "beginConfiguration", #selector(AVCaptureSession.shimulator_beginConfiguration)),
    (session, "commitConfiguration", #selector(AVCaptureSession.shimulator_commitConfiguration)),
    (
      AVCaptureMovieFileOutput.self, "startRecordingToOutputFileURL:recordingDelegate:",
      #selector(AVCaptureMovieFileOutput.shimulator_startRecording(to:recordingDelegate:))
    ),
    (AVCaptureMovieFileOutput.self, "stopRecording", #selector(AVCaptureMovieFileOutput.shimulator_stopRecording)),
    (AVCaptureMovieFileOutput.self, "isRecording", #selector(getter: AVCaptureMovieFileOutput.shimulator_isRecording)),
    (AVCapturePhotoOutput.self, "capturePhotoWithSettings:delegate:", #selector(AVCapturePhotoOutput.shimulator_capturePhoto(with:delegate:))),
    (AVCaptureVideoPreviewLayer.self, "session", #selector(getter: AVCaptureVideoPreviewLayer.shimulator_session)),
    (AVCaptureVideoPreviewLayer.self, "connection", #selector(getter: AVCaptureVideoPreviewLayer.shimulator_connection)),
    (
      AVCaptureVideoPreviewLayer.self, "metadataOutputRectOfInterestForRect:",
      #selector(AVCaptureVideoPreviewLayer.shimulator_metadataOutputRectOfInterest(for:))
    ),
    (
      AVCaptureVideoPreviewLayer.self, "rectForMetadataOutputRectOfInterest:",
      #selector(AVCaptureVideoPreviewLayer.shimulator_rectForMetadataOutputRectOfInterest(_:))
    ),
    (
      AVCaptureVideoPreviewLayer.self, "captureDevicePointOfInterestForPoint:",
      #selector(AVCaptureVideoPreviewLayer.shimulator_captureDevicePointOfInterest(for:))
    ),
    (
      AVCaptureVideoPreviewLayer.self, "pointForCaptureDevicePointOfInterest:",
      #selector(AVCaptureVideoPreviewLayer.shimulator_pointForCaptureDevicePointOfInterest(_:))
    ),
    (AVCaptureVideoPreviewLayer.self, "setSession:", #selector(AVCaptureVideoPreviewLayer.shimulator_setSession(_:))),
    (AVCaptureVideoPreviewLayer.self, "initWithSession:", NSSelectorFromString("initShimulatorWithSession:")),
  ]
  for (cls, name, replacement): (AnyClass?, String, Selector) in swizzles {
    let original = NSSelectorFromString(name)
    guard let cls, let originalMethod = class_getInstanceMethod(cls, original), let replacementMethod = class_getInstanceMethod(cls, replacement) else {
      debug("no method to swizzle: \(name) on \(String(describing: cls))")
      continue
    }
    // An inherited method is copied onto `cls` first, so the exchange never reaches the superclass.
    class_addMethod(cls, original, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
    class_getInstanceMethod(cls, original).map { method_exchangeImplementations($0, replacementMethod) }
  }
}

private func isVirtual(_ output: AVCaptureOutput) -> Bool {
  output is AVCaptureVideoDataOutput || output is AVCaptureMovieFileOutput || output is AVCapturePhotoOutput
}

extension AVCaptureDevice {
  @objc dynamic class func shimulator_defaultDevice(for mediaType: AVMediaType) -> AVCaptureDevice? {
    mediaType == .video ? VirtualCamera.shared.devices.first : shimulator_defaultDevice(for: mediaType)
  }

  @objc dynamic class func shimulator_defaultDevice(_ type: DeviceType, for mediaType: AVMediaType?, position: Position) -> AVCaptureDevice? {
    guard mediaType == nil || mediaType == .video, type == .builtInWideAngleCamera else {
      return shimulator_defaultDevice(type, for: mediaType, position: position)
    }
    return VirtualCamera.shared.devices(at: position).first
  }

  @objc dynamic class func shimulator_devices(for mediaType: AVMediaType) -> [AVCaptureDevice] {
    shimulator_devices(for: mediaType) + (mediaType == .video ? VirtualCamera.shared.devices : [])
  }

  @objc dynamic class func shimulator_devices() -> [AVCaptureDevice] {
    shimulator_devices() + VirtualCamera.shared.devices
  }

  @objc dynamic class func shimulator_device(uniqueID: String) -> AVCaptureDevice? {
    VirtualCamera.shared.devices.first { $0.uniqueID == uniqueID } ?? shimulator_device(uniqueID: uniqueID)
  }

  @objc dynamic class var shimulator_systemPreferredCamera: AVCaptureDevice? { VirtualCamera.shared.devices.first }

  @objc dynamic class var shimulator_userPreferredCamera: AVCaptureDevice? { VirtualCamera.shared.devices.first }

  @objc dynamic class func shimulator_authorizationStatus(for mediaType: AVMediaType) -> AVAuthorizationStatus {
    mediaType == .video ? .authorized : shimulator_authorizationStatus(for: mediaType)
  }

  @objc dynamic class func shimulator_requestAccess(for mediaType: AVMediaType, completionHandler handler: ((Bool) -> Void)?) {
    guard mediaType == .video else { return shimulator_requestAccess(for: mediaType, completionHandler: handler) }
    DispatchQueue.global().async { handler?(true) }
  }
}

extension AVCaptureDevice.DiscoverySession {
  @objc dynamic class func shimulator_discoverySession(deviceTypes: [AVCaptureDevice.DeviceType], mediaType: AVMediaType?, position: AVCaptureDevice.Position) -> AVCaptureDevice.DiscoverySession {
    guard mediaType == nil || mediaType == .video, deviceTypes.contains(.builtInWideAngleCamera) else {
      return shimulator_discoverySession(deviceTypes: deviceTypes, mediaType: mediaType, position: position)
    }
    let session = ShimulatorCaptureDiscoverySession()
    session.virtualDevices = VirtualCamera.shared.devices(at: position)
    return session
  }
}

extension AVCaptureOutput {
  @objc dynamic var shimulator_connections: [AVCaptureConnection] {
    virtualConnection(self).map { [$0] } ?? withNativeView(connectionSession(self)) { self.shimulator_connections }
  }

  @objc dynamic func shimulator_connection(with mediaType: AVMediaType) -> AVCaptureConnection? {
    guard mediaType == .video, let connection = virtualConnection(self) else {
      return withNativeView(connectionSession(self)) { shimulator_connection(with: mediaType) }
    }
    return connection
  }
}

extension AVCaptureSession {
  private func handoffNativeGraph(_ input: AVCaptureInput? = nil, running: Bool? = nil, commit: Bool = true) -> Bool? {
    guard let state = sessionState(self),
      let saved = synchronized(state, { state.input == nil ? (state.outputs, state.preset, state.running) : nil })
    else { return nil }
    let (outputs, preset, wasRunning) = saved
    let camera = VirtualCamera.shared
    camera.setReceivesFrames(self, false)
    return withNativeView(self) {
      let nativeOutputs = shimulator_outputs
      let nativePreset = shimulator_sessionPreset
      shimulator_beginConfiguration()
      var addedInput = false
      var transferred = false
      var addedOutputs: [AVCaptureOutput] = []
      defer {
        if !transferred {
          addedOutputs.reversed().forEach { shimulator_removeOutput($0) }
          if addedInput, let input { shimulator_removeInput(input) }
          shimulator_sessionPreset = nativePreset
        }
        shimulator_commitConfiguration()
        if transferred { camera.restoreNativePreviews(self) }
      }
      if let input {
        guard shimulator_canAddInput(input) else { return false }
        shimulator_addInput(input)
        addedInput = true
      }
      guard shimulator_canSetSessionPreset(preset) else { return false }
      shimulator_sessionPreset = preset
      for output in outputs where !nativeOutputs.contains(where: { $0 === output }) {
        guard shimulator_canAddOutput(output) else { return false }
        shimulator_addOutput(output)
        addedOutputs.append(output)
      }
      guard commit else { return true }
      let suppressed = synchronized(self) {
        (0..<configurations.count).filter { configurations.object(at: $0) as? Bool == false }
      }
      for index in suppressed {
        shimulator_beginConfiguration()
        synchronized(self) { configurations.replaceObject(at: index, with: true) }
      }
      for output in outputs {
        synchronized(output) {
          associate(output, &Key.pending, nil)
          associate(output, &Key.connection, nil)
        }
      }
      synchronized(state) { state.outputs.removeAll() }
      associate(self, &Key.state, nil)
      associate(self, &Key.nativeRunning, NSNumber(value: running ?? wasRunning))
      transferred = true
      return true
    }
  }

  /// A native commit fails on the simulator and AVFoundation later posts that as a runtime error, so a
  /// session commits nothing natively until it holds a native input; `handoffNativeGraph` replays it then.
  private var holdsConfiguration: Bool {
    sessionState(self) != nil || (!isNativeHandoff(self) && !shimulator_isRunning && shimulator_inputs.isEmpty)
  }

  private func heldState() -> SessionState? {
    holdsConfiguration ? sessionState(self, create: true) : nil
  }

  private func rejectNativeHandoff() {
    NSException(name: .invalidArgumentException, reason: "The retained camera graph is incompatible with the native session", userInfo: nil).raise()
  }

  private func stopNativeRunning() {
    withNativeView(self) { shimulator_stopRunning() }
  }

  private func resumeNativeRunningIfReady() {
    guard synchronized(self, { configurations.count == 0 }) else { return }
    if let state: SessionState = associated(self, &Key.state),
      synchronized(
        state,
        {
          defer { state.nativeAudioStartPending = false }
          return state.nativeAudioStartPending && state.input != nil && state.running
        })
    {
      return withNativeView(self) {
        guard shimulator_inputs.contains(where: { $0.ports.contains { $0.mediaType == .audio } }), !shimulator_isRunning else { return }
        shimulator_startRunning()
      }
    }
    guard let running: NSNumber = associated(self, &Key.nativeRunning),
      !running.boolValue || (associated(self, &Key.state) as SessionState?) == nil
    else { return }
    withNativeView(self) {
      associate(self, &Key.nativeRunning, nil)
      if running.boolValue != shimulator_isRunning {
        running.boolValue ? shimulator_startRunning() : shimulator_stopRunning()
      }
    }
  }

  @objc dynamic func shimulator_canAddInput(_ input: AVCaptureInput) -> Bool {
    input is ShimulatorCaptureDeviceInput || (handoffNativeGraph(input, commit: false) ?? withNativeView(self) { shimulator_canAddInput(input) })
  }

  @objc dynamic func shimulator_addInput(_ input: AVCaptureInput) {
    guard let input = input as? ShimulatorCaptureDeviceInput else {
      if let accepted = handoffNativeGraph(input) {
        guard accepted else { return rejectNativeHandoff() }
        resumeNativeRunningIfReady()
      } else {
        withNativeView(self) { shimulator_addInput(input) }
      }
      return
    }
    let camera = VirtualCamera.shared
    let adopting = sessionState(self) == nil
    let pendingRunning: NSNumber? = associated(self, &Key.nativeRunning)
    let (adopted, preset, wasRunning) =
      adopting
      ? withNativeView(self) { (shimulator_outputs, shimulator_sessionPreset, pendingRunning?.boolValue ?? shimulator_isRunning) } : ([], nil, false)
    associate(self, &Key.nativeRunning, pendingRunning?.boolValue == false ? pendingRunning : nil)
    guard let state = sessionState(self, create: true) else { return }
    let (retained, resume) = synchronized(state) { () -> ([AVCaptureOutput], Bool) in
      state.input = input
      state.nativeAudioStartPending = false
      state.preset = preset ?? state.preset
      state.running = state.running || wasRunning
      return (state.outputs, state.running)
    }
    for output in adopted where isVirtual(output) {
      withNativeView(self) { shimulator_removeOutput(output) }
      camera.session(self, added: output)
    }
    retained.forEach { camera.session(self, added: $0) }
    if resume { camera.setReceivesFrames(self, true) }
  }

  /// `-[AVCaptureSession dealloc]` calls this until `inputs` is empty, so the two are swizzled together.
  @objc dynamic func shimulator_removeInput(_ input: AVCaptureInput) {
    if let state = sessionState(self) { synchronized(state) { state.nativeAudioStartPending = false } }
    guard let state = sessionState(self),
      case let (wasRunning, outputs)? = synchronized(
        state,
        { () -> (Bool, [AVCaptureOutput])? in
          guard state.input === input else { return nil }
          state.input = nil
          state.outputs.forEach { virtualConnection($0)?.virtualPorts = [] }
          return (state.running, state.outputs)
        })
    else {
      guard !(input is ShimulatorCaptureDeviceInput) else { return }
      return withNativeView(self) { shimulator_removeInput(input) }
    }
    if wasRunning { VirtualCamera.shared.setReceivesFrames(self, false) }
    outputs.compactMap { $0 as? AVCaptureMovieFileOutput }.forEach(VirtualCamera.shared.stopRecording)
  }

  @objc dynamic var shimulator_inputs: [AVCaptureInput] {
    guard let state = sessionState(self) else { return self.shimulator_inputs }
    let inputs: [AVCaptureInput] = synchronized(state) { state.input.map { [$0] } ?? [] }
    return withNativeView(self) { self.shimulator_inputs } + inputs
  }

  @objc dynamic func shimulator_canAddOutput(_ output: AVCaptureOutput) -> Bool {
    (isVirtual(output) && holdsConfiguration) || withNativeView(self) { shimulator_canAddOutput(output) }
  }

  @objc dynamic func shimulator_addOutput(_ output: AVCaptureOutput) {
    guard isVirtual(output), heldState() != nil else { return withNativeView(self) { shimulator_addOutput(output) } }
    VirtualCamera.shared.session(self, added: output)
  }

  @objc dynamic func shimulator_removeOutput(_ output: AVCaptureOutput) {
    if let state = sessionState(self) { synchronized(state) { state.nativeAudioStartPending = false } }
    guard let state = sessionState(self), synchronized(state, { state.outputs.contains(output) }) else {
      return withNativeView(self) { shimulator_removeOutput(output) }
    }
    synchronized(output) { associate(output, &Key.pending, nil) }
    // Stopped while the output still reports its connection to the recording delegate.
    (output as? AVCaptureMovieFileOutput).map(VirtualCamera.shared.stopRecording)
    synchronized(state) { state.outputs.removeAll { $0 == output } }
    associate(output, &Key.connection, nil)
  }

  @objc dynamic var shimulator_outputs: [AVCaptureOutput] {
    guard let state = sessionState(self) else { return self.shimulator_outputs }
    let outputs = synchronized(state) { state.outputs }
    return withNativeView(self) { self.shimulator_outputs } + outputs
  }

  @objc dynamic var shimulator_connections: [AVCaptureConnection] {
    guard let state = sessionState(self) else { return self.shimulator_connections }
    let connections: [AVCaptureConnection] = synchronized(state) { state.outputs }.compactMap { virtualConnection($0) }.filter { !$0.virtualPorts.isEmpty }
    return withNativeView(self) { self.shimulator_connections } + connections
  }

  @objc dynamic func shimulator_canSetSessionPreset(_ preset: Preset) -> Bool {
    holdsConfiguration || withNativeView(self) { shimulator_canSetSessionPreset(preset) }
  }

  @objc dynamic var shimulator_sessionPreset: Preset {
    get { sessionState(self).map { state in synchronized(state) { state.preset } } ?? withNativeView(self) { self.shimulator_sessionPreset } }
    set {
      guard let state = heldState() else {
        withNativeView(self) { self.shimulator_sessionPreset = newValue }
        return
      }
      synchronized(state) { state.preset = newValue }
    }
  }

  @objc dynamic func shimulator_startRunning() {
    if isNativeHandoff(self) { return shimulator_startRunning() }
    if let accepted = handoffNativeGraph(running: true) {
      guard accepted else { return rejectNativeHandoff() }
      return resumeNativeRunningIfReady()
    }
    if let state = sessionState(self) {
      associate(self, &Key.nativeRunning, nil)
      synchronized(state) { state.nativeAudioStartPending = true }
      VirtualCamera.shared.start(self)
      return resumeNativeRunningIfReady()
    }
    if associated(self, &Key.nativeRunning) as NSNumber? != nil {
      associate(self, &Key.nativeRunning, true)
      return resumeNativeRunningIfReady()
    }
    shimulator_startRunning()
  }

  @objc dynamic func shimulator_stopRunning() {
    if isNativeHandoff(self) { return shimulator_stopRunning() }
    if let state = sessionState(self) {
      synchronized(state) { state.nativeAudioStartPending = false }
      if associated(self, &Key.nativeRunning) as NSNumber? != nil { associate(self, &Key.nativeRunning, false) }
      stopNativeRunning()
      return VirtualCamera.shared.stop(self)
    }
    if associated(self, &Key.nativeRunning) as NSNumber? != nil {
      associate(self, &Key.nativeRunning, false)
      stopNativeRunning()
      return resumeNativeRunningIfReady()
    }
    shimulator_stopRunning()
  }

  @objc dynamic var shimulator_isRunning: Bool {
    if isNativeHandoff(self) { return self.shimulator_isRunning }
    if let state = sessionState(self) { return synchronized(state) { state.running } }
    return (associated(self, &Key.nativeRunning) as NSNumber?)?.boolValue ?? self.shimulator_isRunning
  }

  private var configurations: NSMutableArray {
    if let stack: NSMutableArray = associated(self, &Key.configurations) { return stack }
    let stack = NSMutableArray()
    associate(self, &Key.configurations, stack)
    return stack
  }

  @objc dynamic func shimulator_beginConfiguration() {
    if isNativeHandoff(self) { return shimulator_beginConfiguration() }
    let forward = heldState() == nil
    synchronized(self) { configurations.add(forward) }
    if forward { withNativeView(self) { shimulator_beginConfiguration() } }
  }

  @objc dynamic func shimulator_commitConfiguration() {
    if isNativeHandoff(self) { return shimulator_commitConfiguration() }
    let (forward, matched) = synchronized(self) { () -> (Bool, Bool) in
      defer { if configurations.count > 0 { configurations.removeLastObject() } }
      return (configurations.lastObject as? Bool ?? true, configurations.count > 0)
    }
    if forward { withNativeView(self) { shimulator_commitConfiguration() } }
    if matched { resumeNativeRunningIfReady() }
  }
}

extension AVCaptureMovieFileOutput {
  private var isVirtualTarget: Bool {
    let connection: ShimulatorCaptureConnection? = associated(self, &Key.connection)
    guard !isNativeHandoff(connection?.virtualSession) else { return false }
    return virtualConnection(self) != nil
      || ((associated(self, &Key.recording) as MovieRecording?) != nil && VirtualCamera.shared.isRecording(self))
  }

  @objc dynamic func shimulator_startRecording(to url: URL, recordingDelegate delegate: AVCaptureFileOutputRecordingDelegate) {
    guard virtualConnection(self) != nil else {
      return withNativeView(connectionSession(self)) { shimulator_startRecording(to: url, recordingDelegate: delegate) }
    }
    VirtualCamera.shared.startRecording(self, to: url, delegate: delegate)
  }

  @objc dynamic func shimulator_stopRecording() {
    isVirtualTarget ? VirtualCamera.shared.stopRecording(self) : withNativeView(connectionSession(self)) { shimulator_stopRecording() }
  }

  @objc dynamic var shimulator_isRecording: Bool {
    isVirtualTarget ? VirtualCamera.shared.isRecording(self) : withNativeView(connectionSession(self)) { self.shimulator_isRecording }
  }
}

extension AVCapturePhotoOutput {
  @objc dynamic func shimulator_capturePhoto(with settings: AVCapturePhotoSettings, delegate: AVCapturePhotoCaptureDelegate) {
    guard virtualConnection(self) != nil else {
      return withNativeView(connectionSession(self)) { shimulator_capturePhoto(with: settings, delegate: delegate) }
    }
    VirtualCamera.shared.capturePhoto(self, settings: settings, delegate: delegate)
  }
}

extension AVCaptureVideoPreviewLayer {
  @objc dynamic var shimulator_session: AVCaptureSession? {
    associated(self, &Key.previewSession) ?? self.shimulator_session
  }

  @objc dynamic var shimulator_connection: AVCaptureConnection? {
    let session: AVCaptureSession? = associated(self, &Key.previewSession)
    guard let state = sessionState(session) else { return self.shimulator_connection }
    return synchronized(self) {
      let current: ShimulatorCaptureConnection? = associated(self, &Key.previewConnection)
      let connection = synchronized(state) { () -> ShimulatorCaptureConnection? in
        guard let ports = state.input?.ports else { return nil }
        if let current, current.virtualPorts == ports { return current }
        // A new input (a camera switch) keeps what the app set on the old connection.
        let replacement = makeConnection(ports, session, rotationAngle: current?.storedRotationAngle ?? 90)
        replacement.storedEnabled = current?.storedEnabled ?? true
        replacement.storedAutomaticallyAdjustsMirroring = current?.storedAutomaticallyAdjustsMirroring ?? true
        replacement.storedMirrored = current?.storedMirrored ?? false
        return replacement
      }
      associate(self, &Key.previewConnection, connection)
      return connection
    }
  }

  /// Maps the normalised native frame onto the layer as the preview shows it: turned by the angle
  /// the frames are turned by, mirrored when the connection is, and placed by `videoGravity`.
  private var virtualFrameTransform: CGAffineTransform? {
    guard let connection = connection as? ShimulatorCaptureConnection else { return nil }
    let size = frameSize(connection)
    let bounds = self.bounds
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
    var video = bounds
    if videoGravity != .resize {
      let widthScale = bounds.width / size.width
      let heightScale = bounds.height / size.height
      let scale = videoGravity == .resizeAspectFill ? max(widthScale, heightScale) : min(widthScale, heightScale)
      video.size = CGSize(width: size.width * scale, height: size.height * scale)
      video.origin = CGPoint(x: bounds.midX - video.width / 2, y: bounds.midY - video.height / 2)
    }
    let rotations: [CGFloat: CGAffineTransform] = [
      90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0),
      180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0),
      270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0),
    ]
    return CGAffineTransform(translationX: -0.5, y: -0.5)
      .concatenating(rotations[connection.frameRotationAngle] ?? .identity)
      .concatenating(CGAffineTransform(a: connection.isVideoMirrored ? -1 : 1, b: 0, c: 0, d: 1, tx: 0.5, ty: 0.5))
      .concatenating(CGAffineTransform(a: video.width, b: 0, c: 0, d: video.height, tx: video.minX, ty: video.minY))
  }

  @objc dynamic func shimulator_metadataOutputRectOfInterest(for rect: CGRect) -> CGRect {
    guard let transform = virtualFrameTransform else { return shimulator_metadataOutputRectOfInterest(for: rect) }
    return rect.applying(transform.inverted())
  }

  @objc dynamic func shimulator_rectForMetadataOutputRectOfInterest(_ rect: CGRect) -> CGRect {
    guard let transform = virtualFrameTransform else { return shimulator_rectForMetadataOutputRectOfInterest(rect) }
    return rect.applying(transform)
  }

  @objc dynamic func shimulator_captureDevicePointOfInterest(for point: CGPoint) -> CGPoint {
    guard let transform = virtualFrameTransform else { return shimulator_captureDevicePointOfInterest(for: point) }
    return point.applying(transform.inverted())
  }

  @objc dynamic func shimulator_pointForCaptureDevicePointOfInterest(_ point: CGPoint) -> CGPoint {
    guard let transform = virtualFrameTransform else { return shimulator_pointForCaptureDevicePointOfInterest(point) }
    return point.applying(transform)
  }

  @objc dynamic func shimulator_setSession(_ session: AVCaptureSession?) {
    VirtualCamera.shared.track(self, session: session)
    if sessionState(session) == nil { shimulator_setSession(session) }
  }
}
