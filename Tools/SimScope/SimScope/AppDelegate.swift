/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AppKit
import FBControlCore
import FBSimulatorControl
import SimScopeProtocol

/// Application lifecycle only: the menu bar, the signal handlers, and the registry of device windows.
/// Everything scoped to one simulator — its window, session, recorders and agent socket — lives on
/// `DeviceWindowController`, which is what lets a second device be a second controller rather than a
/// second app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

  /// Strongly held: a window controller is not retained by its window, and every one of these owns a
  /// take that must be finalized and a socket that must be unlinked on the way out.
  private var deviceControllers: [DeviceWindowController] = []
  /// Retained for the process's lifetime; a released signal source stops delivering.
  private var signalSources: [any DispatchSourceSignal] = []
  /// The last still fetched per device, so a reopened menu shows something at once while a fresh
  /// fetch replaces it — a list that appears instantly and fills in beats one that waits to be right.
  private var thumbnails: [String: NSImage] = [:]

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildMenu()
    installSignalHandlers()
    do {
      let backend = try DeviceCatalog.shared.connectBooted(udid: LaunchArguments.argument("--udid"))
      NSLog("SimScope: connected to %@ (%@), pointSize=%@", backend.simulator.name, backend.simulator.udid, "\(backend.pointSize)")
      // The launch window binds the base path as well as its own, so an agent that never chose a
      // device keeps talking to the window the app was launched for.
      adopt(
        DeviceWindowController(
          backend: backend,
          controlSocketPaths: [
            Self.baseSocketPath,
            ControlSocket.path(forUDID: backend.simulator.udid, beside: Self.baseSocketPath),
          ]))
    } catch {
      presentSimScopeError(error, message: "SimScope could not connect to a booted iOS Simulator.", fatal: true)
    }
    // `--open <udid>`, repeatable — additional windows from launch, through the same path the
    // Simulator menu takes. What makes multi-window scriptable, and therefore testable.
    for udid in LaunchArguments.values("--open") { openWindow(udid: udid) }
  }

  /// The app outlives its windows: closing the last device window leaves the menu bar up, and the
  /// Simulator menu can open another. Quitting is ⌘Q or a signal, as it always was.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  private static var baseSocketPath: String {
    LaunchArguments.argument("--control-socket") ?? ControlSocket.defaultPath
  }

  private func adopt(_ controller: DeviceWindowController) {
    controller.onClose = { [weak self] closed in
      self?.deviceControllers.removeAll { $0 === closed }
    }
    deviceControllers.append(controller)
  }

  /// Routes a terminal kill through the app's own quit path.
  ///
  /// SimScope is started from a shell, so `^C` and `pkill` are how a session usually ends — and the
  /// default disposition for both signals is to die on the spot, mid-take, leaving a movie with no
  /// `moov` atom that no player will open. `SIG_IGN` first: a dispatch source only gets a look in once
  /// the default action is out of the way.
  private func installSignalHandlers() {
    for number in [SIGINT, SIGTERM] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler {
        NSLog("SimScope: caught signal %d — quitting", number)
        NSApp.terminate(nil)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    for controller in deviceControllers { controller.finalizeWindowRecordingBlocking() }
    return .terminateNow
  }

  // MARK: - Opening simulators

  /// Rebuilds the Open Simulator submenu each time it is shown, so the list is the device sets as
  /// they stand rather than as they stood at launch. Booted simulators open; the rest are listed
  /// disabled, because seeing what exists is half of why anyone opens this menu. With more than one
  /// set the devices are grouped under a header per set — the standard set first, then each chosen
  /// one — and a set whose directory has gone says so instead of disappearing.
  func menuNeedsUpdate(_ menu: NSMenu) {
    populateSimulatorMenu(menu)
  }

  /// Shows the same list from the title-bar switcher of any device window; the button reaches this
  /// through the responder chain, which ends at the app delegate.
  @objc func popUpSimulatorMenu(_ sender: Any?) {
    guard let view = sender as? NSView else { return }
    let menu = NSMenu(title: "Open Simulator")
    menu.autoenablesItems = false
    populateSimulatorMenu(menu)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 4), in: view)
  }

  private func populateSimulatorMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    let open = Set(deviceControllers.map { $0.backend.simulator.udid })
    let listings = DeviceCatalog.shared.listings()

    for (index, listing) in listings.enumerated() {
      if index > 0 { menu.addItem(.separator()) }
      // A lone standard set needs no header; the grouping only says anything once sets can differ.
      if listings.count > 1 {
        let title = listing.available ? listing.label : "\(listing.label) — unavailable"
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
      }
      if listing.available && listing.devices.isEmpty {
        let empty = menu.addItem(withTitle: "No simulators", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        empty.indentationLevel = listings.count > 1 ? 1 : 0
      }
      for device in listing.devices {
        let item = menu.addItem(
          withTitle: "\(device.name) — \(device.state)", action: #selector(openSimulator(_:)),
          keyEquivalent: "")
        item.target = self
        item.representedObject = device.udid
        item.state = open.contains(device.udid) ? .on : .off
        item.isEnabled = device.isBooted
        item.indentationLevel = listings.count > 1 ? 1 : 0
        item.image = thumbnails[device.udid] ?? Self.placeholderThumbnail
        if device.isBooted { refreshThumbnail(udid: device.udid, item: item) }
      }
      if case let .custom(path) = listing.identity {
        let forget = menu.addItem(
          withTitle: "Forget This Set", action: #selector(forgetDeviceSet(_:)), keyEquivalent: "")
        forget.target = self
        forget.representedObject = path
        forget.indentationLevel = 1
      }
    }

    menu.addItem(.separator())
    let choose = menu.addItem(
      withTitle: "Choose Device Set…", action: #selector(chooseDeviceSet), keyEquivalent: "")
    choose.target = self
  }

  private static let placeholderThumbnail = NSImage(
    systemSymbolName: "iphone", accessibilityDescription: "simulator")

  /// Refreshes one row's still, keeping the menu instant: the row opens with whatever was cached and
  /// the fresh image lands when the fetch returns. A device already open in a window is snapshotted
  /// from that window's own surface rather than attaching a second framebuffer to it.
  private func refreshThumbnail(udid: String, item: NSMenuItem) {
    if let controller = deviceControllers.first(where: { $0.backend.simulator.udid == udid }) {
      if let cg = controller.currentScreenImage() {
        let image = Self.menuImage(from: cg)
        thumbnails[udid] = image
        item.image = image
      }
      return
    }
    Task { @MainActor in
      guard let cg = await DeviceCatalog.shared.thumbnailImage(udid: udid) else { return }
      let image = Self.menuImage(from: cg)
      thumbnails[udid] = image
      item.image = image
    }
  }

  /// Menu-row sized, aspect preserved: tall and narrow, like the screen it is.
  private static func menuImage(from cg: CGImage) -> NSImage {
    let height: CGFloat = 44
    let aspect = CGFloat(cg.width) / CGFloat(max(cg.height, 1))
    return NSImage(cgImage: cg, size: NSSize(width: height * aspect, height: height))
  }

  /// A device set is a directory and CoreSimulator cannot enumerate them, so new sets arrive by
  /// being pointed at: the chosen path is remembered across launches and its simulators join the menu.
  @objc private func chooseDeviceSet() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    // ast-grep-ignore: common/swift/i18n-hardcoded-ui-property
    panel.message = "Choose a CoreSimulator device set directory"
    // ast-grep-ignore: common/swift/i18n-hardcoded-ui-property
    panel.prompt = "Add Set"
    panel.directoryURL = URL(fileURLWithPath: DeviceSetIdentity.standardPath).deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    DeviceCatalog.shared.remember(path: url.path)
  }

  @objc private func forgetDeviceSet(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    DeviceCatalog.shared.forget(path: path)
  }

  /// A device that already has a window comes forward rather than opening twice: two windows on one
  /// simulator would be two sessions both claiming to be the record of it.
  @objc private func openSimulator(_ sender: NSMenuItem) {
    guard let udid = sender.representedObject as? String else { return }
    openWindow(udid: udid)
  }

  private func openWindow(udid: String) {
    if let existing = deviceControllers.first(where: { $0.backend.simulator.udid == udid }) {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    do {
      let backend = try DeviceCatalog.shared.connectBooted(udid: udid)
      NSLog("SimScope: connected to %@ (%@), pointSize=%@", backend.simulator.name, backend.simulator.udid, "\(backend.pointSize)")
      adopt(
        DeviceWindowController(
          backend: backend,
          controlSocketPaths: [
            ControlSocket.path(forUDID: backend.simulator.udid, beside: Self.baseSocketPath)
          ]))
    } catch {
      presentSimScopeError(error, message: "SimScope could not open that simulator.")
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    for controller in deviceControllers { controller.shutdown() }
  }

  // MARK: - Menu

  /// Window-scoped items carry nil targets, so the responder chain resolves each action to the key
  /// window's controller — the action lands on the window it was invoked from, which is the property
  /// that matters once there is more than one.
  private func buildMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About SimScope", action: nil, keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit SimScope", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    let simulatorMenuItem = NSMenuItem()
    mainMenu.addItem(simulatorMenuItem)
    let simulatorMenu = NSMenu(title: "Simulator")
    let openItem = NSMenuItem(title: "Open Simulator", action: nil, keyEquivalent: "")
    let openSubmenu = NSMenu(title: "Open Simulator")
    openSubmenu.delegate = self
    // Enabling is decided in `menuNeedsUpdate`; auto-enabling would light up every simulator in the
    // set, and opening a shutdown one has nothing to attach to.
    openSubmenu.autoenablesItems = false
    openItem.submenu = openSubmenu
    simulatorMenu.addItem(openItem)
    simulatorMenuItem.submenu = simulatorMenu

    let deviceMenuItem = NSMenuItem()
    mainMenu.addItem(deviceMenuItem)
    let deviceMenu = NSMenu(title: "Device")
    for spec in DeviceAction.all {
      let item = deviceMenu.addItem(
        withTitle: spec.label, action: #selector(DeviceWindowController.deviceMenuSelected(_:)),
        keyEquivalent: "")
      item.representedObject = spec.name
    }
    deviceMenuItem.submenu = deviceMenu

    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(viewMenuItem)
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(
      withTitle: "Toggle Overlay", action: #selector(DeviceWindowController.toggleOverlay), keyEquivalent: "o")
    viewMenu.addItem(
      withTitle: "Show All Tree Elements", action: #selector(DeviceWindowController.toggleTreeFilter),
      keyEquivalent: "e")
    viewMenu.addItem(
      withTitle: "Connect Hardware Keyboard",
      action: #selector(DeviceWindowController.toggleHardwareKeyboard), keyEquivalent: "k")
    viewMenuItem.submenu = viewMenu

    let sessionMenuItem = NSMenuItem()
    mainMenu.addItem(sessionMenuItem)
    let sessionMenu = NSMenu(title: "Session")
    sessionMenu.addItem(
      withTitle: "Start Recording", action: #selector(DeviceWindowController.toggleRecording), keyEquivalent: "r")
    let windowRecord = sessionMenu.addItem(
      withTitle: "Record This Window", action: #selector(DeviceWindowController.toggleWindowRecording),
      keyEquivalent: "r")
    windowRecord.keyEquivalentModifierMask = [.command, .shift]
    sessionMenu.addItem(
      withTitle: "Repeat My Actions", action: #selector(DeviceWindowController.repeatMyActions), keyEquivalent: "")
    let console = sessionMenu.addItem(
      withTitle: "Swift Console…", action: #selector(DeviceWindowController.showSwiftConsole), keyEquivalent: "j")
    console.keyEquivalentModifierMask = [.command, .shift]
    sessionMenuItem.submenu = sessionMenu

    NSApp.mainMenu = mainMenu
  }
}
