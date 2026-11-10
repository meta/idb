# FBSimulatorControl

A macOS library for managing, booting and interacting with multiple iOS Simulators simultaneously.

`FBSimulatorControl` is primarily an implementation detail of `idb`: the `idb_companion` is its main consumer, and for most automation `idb` is the better choice. The framework is also built to be used directly, for two main reasons:

- **Building native macOS applications.** A macOS application can link the framework and control Simulators in-process, with no separate client, gRPC hop, or companion lifecycle to manage. That includes [building a new simulator app](#functionality-beyond-apples-tools) that renders and drives the screen itself. [qalti](https://github.com/qalti/qalti), for example, embeds the idb frameworks directly inside a macOS testing product.
- **Finer-grained control.** The framework exposes more than the `idb` cli surfaces, such as direct framebuffer access, live video streaming, HID event synthesis and boot configuration. It also lets a consumer combine that functionality in ways the cli deliberately simplifies. [serve-sim](https://github.com/EvanBacon/serve-sim) ported the framework's host-side accessibility reading into its own server.

The trade-off is stability. The `idb` cli and its gRPC interface are the project's compatibility boundary and change conservatively. The frameworks are the implementation behind that boundary, so their APIs change more freely. A direct consumer should expect to track those changes when updating.

## Features

- Boots multiple Simulators concurrently on the same host, isolated in custom 'Device Sets'.
- Boots iOS Simulators across a range of Xcode and iOS Versions.
- Runs independently of Xcode and `xcodebuild` without requiring embedding in a Graphical User Interface. Uses whatever Xcode toolchain is defined by `xcode-select`.
- Exposes a broad range of functionality that is available in `simctl` and Xcode.
- Implements additional functionality not available in `simctl` including file manipulation, direct input event injection and more. Hardware-encoded video recording and streaming are in [`FBSimulatorVideo`](../FBSimulatorVideo/README.md), and accessibility reading in [`FBSimulatorAX`](../FBSimulatorAX/README.md).
- No external dependencies.
- A Swift framework. Apple's private frameworks are reached through header-only declarations, not part of the API.

## About

The original use-case for `FBSimulatorControl` was to boot multiple Simulators on the same host, before this was officially supported in Xcode.

`FBSimulatorControl` works by linking with the private `CoreSimulator` and `SimulatorKit` frameworks that are installed as part of Xcode. Doing this allows  `FBSimulatorControl` to talk directly to the same APIs that Xcode and `simctl` use. `FBSimulatorControl` and the libraries built on it also add features that aren't present in Xcode or the iOS Simulator, such as accessibility fetching.

## Installation

idb's libraries are published as static libraries, one XCFramework each, in `idb-libraries.macos-arm64.tar.gz` on each [release](https://github.com/facebook/idb/releases). A consumer takes only the libraries it uses: `FBControlCore` alone, `FBSimulatorControl` and what it builds on, or any of the libraries built on that, such as `FBSimulatorAX` or `FBSimulatorVideo`. The package is assembled from a source build with `./build.sh build libraries`, then `./build.sh build library-package`, which writes it to `Build/LibraryPackage`.

The package holds:

- `<Library>.xcframework` for each library: its static archive, and its Swift module with the textual module interface, so it builds with a different Swift compiler from the one that built it.
- `manifest.json`, for each library: the archives it links (its own and every library it builds on), the SDK frameworks, the linker flags, the search paths its interface needs, and the resources it runs. It is [`LibraryPackage.json`](../LibraryPackage.json), which is generated from the build.
- `PrivateHeaders/`: Apple's private frameworks, declared as idb uses them, with the TBD stubs the simulator libraries' linker flags name.
- `Resources/`: the guest bridges and shims the simulator libraries run inside a simulator.
- `Package.swift`: a SwiftPM product per library.
- `CoreSimulatorStub.xcframework` and `AccessibilityPlatformTranslationStub.xcframework`: small frameworks that re-export Apple's private frameworks, so SwiftPM and Xcode link them like any other framework.

### With SwiftPM

Each release's libraries are a versioned Swift package at [`facebook/homebrew-fb`](https://github.com/facebook/homebrew-fb), whose products fetch the release's XCFrameworks by URL and checksum:

```swift
dependencies: [.package(url: "https://github.com/facebook/homebrew-fb", from: "1.7.0")],
targets: [
  .executableTarget(name: "Tool", dependencies: [.product(name: "FBSimulatorControl", package: "homebrew-fb")]),
]
```

The `Package.swift` in the libraries package offers the same products, for a build of your own: add it as a dependency, unpacked locally or from a git repository holding it:

```swift
dependencies: [.package(path: "path/to/idb-libraries")],
targets: [
  .executableTarget(name: "Tool", dependencies: [.product(name: "FBSimulatorControl", package: "idb-libraries")]),
]
```

The simulator libraries link Apple's private `CoreSimulator` and `AccessibilityPlatformTranslation` frameworks through the stub frameworks, which SwiftPM links without any linker flags, so the package works as a versioned dependency too. Each stub is a dynamic framework: it is copied beside a command-line tool or embedded in an application like any other, and loads the real private framework from its fixed location. The link is a strong one, so a tool that uses the simulator libraries needs Xcode installed to launch, as it does to do anything.

### With Xcode or swiftc

For each library you use, as `manifest.json` lists it:

- Link every archive in `archives`, from its XCFramework, and every framework in `frameworks`.
- Add each archive's XCFramework slice (`<Library>.xcframework/macos-arm64`) to the Swift search paths (`SWIFT_INCLUDE_PATHS`, or `-I`), and each entry of `search_paths` (`PrivateHeaders`, for the simulator libraries) too.
- Give the linker `linker_flags`, with their paths made relative to the package: in `OTHER_LDFLAGS`, or with `-Xlinker` before each for `swiftc`. These weak-link the private frameworks through their TBD stubs; linking the stub frameworks instead, as SwiftPM does, works too.

### Resources

The simulator libraries run helpers inside the simulator: the guest bridge for `FBSimulatorServices` (and the accessibility and REPL libraries built on it), and the shims for XCTest, audio injection and the REPL. `manifest.json` lists each library's; a consumer ships only those of the libraries it links. Point `BundledResources.hostDirectoryPath` at the package's `Resources/` (or wherever you copy it) before using them. Without it, they are looked for in an application's own resources, or in a `Resources/` directory beside the executable. Copy them as they are: the guests are signed for the simulator and must not be re-signed.

## Usage

In order to support different Xcode versions and system environments, `FBSimulatorControl` weakly links against Xcode's Private Frameworks and loads these Frameworks when they are needed. `FBSimulatorControl` will link against the version of Xcode that you have set with [`xcode-select`](https://developer.apple.com/library/mac/documentation/Darwin/Reference/ManPages/man1/xcode-select.1.html). It is not recommended to run against multiple versions of Xcode on the same host as `CoreSimulator` has user-level daemons that cannot run against multiple versions of Xcode concurrently.

Since the Frameworks upon which `FBSimulatorControl` depends are loaded lazily, they must be loaded before the Framework is functional. However, you do not have to do this manually as any of the `FBSimulatorControl` functionality that has this dependency will load these Private Frameworks when they are used for the first time.

[The tests](../FBSimulatorControlTests/Tests) should provide you with some basic guidance for using the API, and the `idb_companion` in this repository is a full-featured consumer of it.

For a high level overview:
- `SimulatorControlBootstrap` is the entry point. It is the first object that you should create, with `SimulatorControlBootstrap(configuration:)`. It creates a `SimulatorSet` upon creation, exposed as `set`.
- `SimulatorSet` wraps `SimDeviceSet` and provides a resilient CRUD API for Deleting, Creating and Erasing Simulators. It is a way of querying a device set, not the owner of the `Simulator`s it returns: it keeps none of them alive.
- `Simulator` is a reference type that represents an individual Simulator. It has a number of convenience methods for accessing information about a Simulator. Many of the possible actions you can perform on a Simulator are present on instances of this class.
- A `Simulator` can also be obtained directly from a `SimDevice` you already have, with `Simulator.fromSimDevice(_:logger:hidEventLogging:)`, without creating a `SimulatorSet`. Either way there is at most one live `Simulator` per device in the process: state such as memoized commands and the HID connection hangs off the instance, so a second instance for the same device would split it. Once nothing holds a `Simulator`, the next request for its device builds a fresh one.
- Configuration values: `ApplicationLaunchConfiguration`, `SimulatorControlConfiguration`, `SimulatorConfiguration` & `SimulatorBootConfiguration`, all structs.


Simulator creation resolves a request against CoreSimulator's installed device types and runtimes:

```swift
let request = SimulatorCreationRequest(device: .name("iPhone 17e"))
let simulator = try await control.set.createSimulator(with: request)
```

Use `.identifier(...)` for an exact CoreSimulator identifier, or `.name(...)` for a display name.
An omitted runtime selects the newest available compatible version, with build numbers breaking
version ties. An explicit runtime must match; it never falls back to another version.
`SimulatorConfiguration.availableConfigurations()` lists available compatible pairs.
A simulator's `configuration` describes its actual device/runtime metadata, including identifiers
and runtime build, even when the runtime is no longer available.
Runtime identifiers do not pin a particular build: CoreSimulator can create the device
using another installed build with the same identifier. Inspect the created simulator's
configuration for its actual runtime build.

The former release constants, configuration catalogs, `defaultConfiguration()`, and fluent
`withDeviceModel` / `withOSNamed` builders have been removed. Construct creation requests directly;
`FBDeviceModel` and `FBOSVersionName` remain open string wrappers for target metadata.


## Functionality beyond Apple's tools

`FBSimulatorControl` supported "Multisim" (booting many Simulators concurrently on one host, headlessly, isolated in custom device sets) years before Xcode and `simctl` did. Apple's tools now provide all of this, so it is no longer a reason to pick the framework.

Even where the functionality overlaps with `simctl`, the framework provides it differently: as an in-process API over a `CoreSimulator` connection that is bound once and reused, rather than a `simctl` process per operation. This makes the framework practical to embed in an application instead of shelling out, and is why individual operations in the `idb_companion` are fast. The [`simctl` section](#simctl) below describes the difference in detail.

The framework also provides functionality that has no equivalent in `simctl`, `xcodebuild` or the host app. Most of it is built on protocols and services that Apple's own tools use internally but do not expose:

- **Live screen access.** A booted Simulator's screen is available to the linking process as an `IOSurface`-backed framebuffer. The framework turns this into screenshots, and [`FBSimulatorVideo`](../FBSimulatorVideo/README.md) into video files or live streams of hardware-encoded H.264, MJPEG, or raw frames. `simctl` can only record a video file after the fact; it cannot stream, and it cannot give your process access to the GPU-resident surface.
- **Input synthesis.** Touch, keyboard and hardware-button events are delivered over the Simulator's own HID services: the reverse-engineered Indigo mach protocol, or the `dtuhidd` XPC path on newer Xcodes. Device orientation is delivered over GSEvent ("Purple"), and shake via Darwin notifications. Apple's only supported route to synthesized input is an XCUITest bundle.
- **Accessibility reading.** [`FBSimulatorAX`](../FBSimulatorAX/README.md) reads the full element hierarchy of the frontmost application without a test bundle, either through host-side translation or in-guest at XCUITest fidelity via the bundled `SimulatorFrameworkBridge` helper.
- **In-guest state injection.** [`FBSimulatorServices`](../FBSimulatorServices/README.md) runs `SimulatorFrameworkBridge` inside the booted Simulator to modify state that no `simctl` verb reaches, such as overwriting the contacts database or clearing the photo library.

Combined, live screen access, input synthesis and accessibility reading are enough to build a new "simulator app": a macOS application or remote-streaming service that presents and drives Simulators with its own UI and transport, the way `Simulator.app` does.

Continuous, interactive work like this is where the in-process connection matters, and where driving `idb` from a separate process is not sufficient:

- **Frame delivery.** The `idb` cli provides an encoded byte stream. In-process, you get the `IOSurface` itself, GPU-resident and zero-copy, and can feed it to your own view, encoder or pixel analysis at the display's rate.
- **Live input.** The cli synthesizes discrete gestures that are described up front, such as a tap or a swipe. An app following a real pointer needs a persistent HID connection that streams touch positions as they happen, at input-device rates.
- **Long-lived state.** Every cli invocation pays client startup and an RPC round trip, and re-resolves its target. A tight read-decide-act loop is better served by long-lived framework objects that keep the boot, the HID connection and the accessibility session alive between calls.

## How Simulator control works

The framework is built on the private frameworks and services that Apple's own tools use. The sections below describe what each one is and how `FBSimulatorControl` drives it.

### `CoreSimulator.framework`

`CoreSimulator` is the Private Framework that is the interface for most Simulator related functionality on macOS. In previous Xcode versions, `CoreSimulator` was bundled inside of Xcode, but it is now installed at the System level just like `MobileDevice.framework`. It may be upgraded to a newer version as part of the install process of Xcode itself.

`CoreSimulator` is used by Xcode and `simctl` as the Framework used to manipulate Simulators. It has Objective-C classes representing a set of Simulators within a directory (`SimDeviceSet` wrapped by `SimulatorSet`) and an individual iOS Simulator (`SimDevice`, wrapped by `Simulator`). There is also a Class that behaves a lot like an "entrypoint" to the Framework in `SimServiceContext`, this performs initialization of external services and is aware of the various configurations of Simulators that are available.

### `simctl`

`simctl` is a CLI that exposes iOS Simulator functionality by linking and using `CoreSimulator`. This binary is bundled inside of Xcode, and typically addressed via the `xcrun` command. `xcrun` is a trampoline that locates binaries bundled within Xcode, using the value defined in `xcode-select`.

Functionality that is implemented within `CoreSimulator` is shared by all of its clients, so `Simulator.app` and `simctl` behave consistently wherever they use the same Framework implementation.

`FBSimulatorControl` does not shell out to `simctl`; it binds the same `CoreSimulator` APIs that `simctl` is built on. Every `simctl` invocation is a new process, which has to load `CoreSimulator` and establish its XPC connection to `CoreSimulatorService` before it can do any work. For a one-off command this doesn't matter, but the per-exec cost adds up when commands are issued in a hot inner loop. `Simulator.app` and `DeviceHub.app` don't pay this cost, since they hold a single connection to `CoreSimulatorService` for their entire lifetime. A process that links `FBSimulatorControl`, such as the `idb_companion`, behaves the same way: `CoreSimulator` is bound once and reused, so each operation is as fast as it is in Apple's own applications.

### `CoreSimulatorService`

`CoreSimulatorService` is a user-level daemon that is bootstrapped by any usage of `SimServiceContext`, effectively any usage of iOS Simulators will cause this service to be created and launched. This is an XPC service contained within the `CoreSimulator.framework` bundle. This service is responsible for starting and managing Simulators.

When using `CoreSimulator` as a client Framework it will transparently communicate with `CoreSimulatorService`. The overwhelming majority of `CoreSimulator` APIs that do meaningful work are performing IO to `CoreSimulatorService`, though the asynchronous nature of this work isn't completely consistent. Some `CoreSimulator` APIs (for instance those associated with [launching an iOS Application](https://github.com/facebook/idb/blob/main/PrivateHeaders/CoreSimulator/SimDevice.h)) do have asynchronous methods, but others (such as the [instantiation of a `SimServiceContext`](https://github.com/facebook/idb/blob/main/PrivateHeaders/CoreSimulator/SimServiceContext.h)) do not. `CoreSimulatorService` still gets much of its implementation from `CoreSimulator.framework`, touching different areas of the API.

Having the "work" of iOS Simulators performed within a shared user daemon is likely due to the need to synchronize and consolidate state. The service is also an effective caching mechanism for runtime and device profiles. There are a few downsides to this approach. Firstly, `CoreSimulatorService` is effectively a single point of failure. If `CoreSimulatorService` becomes stuck, or a client of `CoreSimulator` exhibits pathological behaviour, then all iOS Simulator functionality on a given host will fail. iOS Simulator functionality will effectively halt until `CoreSimulatorService` restarts, either by the hung `CoreSimulatorService` terminating and restarting or via reboot.

Secondly, the lifecycle of `CoreSimulatorService` is tied to that of the selected `Xcode`. This means that different versions of Xcode cannot be used concurrently on the same host; `CoreSimulatorService` can only be aware of a single Xcode at any point in time. Switching Xcodes and fetching a new `CoreSimulatorService` (for instance via a `simctl` command) will cause `CoreSimulatorService` to restart, disconnecting existing clients and killing booted Simulators.

### `SimRuntime`

An iOS Simulator Runtime is all of the required components for running an iOS Simulator of a given iOS version. This is a bundle, where the contents closely match the makeup of the files on disk on a physical device. This includes binaries that are compiled for the host architecture (arm64, since idb runs on Apple silicon Macs) as well as Frameworks. The Frameworks within a SimRuntime match those of iOS, instead of those of the macOS host. There are often subtle differences in the iOS and macOS APIs, even within the same Framework. A single `SimRuntime` represents a single iOS version.

Each version of Xcode is bundled with `SimRuntime`s for the most recent iOS version that is relevant for the Xcode version across iOS, tvOS and watchOS. However, additional iOS Versions can be supported on a given version of Xcode via the "Components" section within `Xcode.app`. These bundles are then installed into `/Library/Developer/CoreSimulator/Profiles/Runtimes` on the host system. Runtime bundles are backwards, but not forwards compatible. For example, Xcode 11 has support for iOS 13 (the latest iOS version associated with this Xcode version) and earlier versions of iOS, but not for iOS 14.

### `launchd_sim`

iOS, like macOS has `launchd` as its "root process" (often PID 1). However, iOS Simulators have their own version of `launchd` as a root process. This `launchd_sim` is effectively the "root process" of the iOS Simulator runtime, but not of the macOS host. This `launchd_sim` is required by the Simulator OS in order to launch Applications, manage services etc. Each launched iOS Simulator has its own `launchd_sim` process, launched from the `launchd_sim` within the `SimRuntime`. This also means that processes within this nested `launchd` will only see the processes of the iOS Simulator, rather than all of those of the entire host (including other iOS Simulators running on the same host).

This `launchd_sim` can be interrogated the same as the `launchd` of the host, provided that the `launchctl` called is spawned within the `launchd_sim` of the iOS Simulator.

### Device Sets

A Device Set is a directory that contains a number of created iOS Simulators. The "Default Device Set" is located at `~/Library/Developer/CoreSimulator/Devices`, this is the device set that is used by `Xcode.app`.

Custom device sets can be placed at any location on disk. This is useful for isolating the filesystems of created iOS Simulators from each other. For instance, if there are independent processes managing iOS Simulators on the same host it can be worthwhile having each of these processes manage their own device sets to prevent data races.

There is also an `XCTestDevices` directory at `~/Library/Developer/XCTestDevices`. This is the set of Simulators that are used by `xcodebuild`, distinct from the user interface. This means that `xcodebuild` can manage and use its own set of iOS Simulators, independent of the Xcode UI. This may exist for similar reasons to why custom device sets are practical for automation scenarios. It would also be a confusing user experience if an iOS Simulator that was being used within `xcodebuild` was using an iOS Simulator that a user was using via Xcode when running UI Tests.

### `Simulator.app`

This is the "Simulator" Application with which most developers will be familiar with. This Application effectively mirrors the state of launched iOS Simulators within `CoreSimulatorService`. It is not an essential part of booting and managing iOS Simulators; iOS Simulators can be booted and used without a `Simulator.app` launched for it. This makes using Simulators more practical in automation scenarios where a running macOS Application representing the iOS Simulator is not important or even desirable.

The Simulator Application will default to showing all iOS Simulators that are within the "Default Device Set". This means that booted iOS Simulators within "Custom Device Sets" will not be displayed within `Simulator.app`.

The functionality within this Application is largely implemented within `CoreSimulator.framework` and `SimulatorKit.framework`, with the UI implemented directly within the application itself.

### `DeviceHub.app` (Xcode 27 and later)

From Xcode 27, the host application is the CoreDevice-based `DeviceHub.app` rather than `Simulator.app`. `FBSimulatorControl` launches whichever host app the active Xcode ships. The behaviour above carries over: `DeviceHub.app` also displays only the default device set, so Simulators in a custom device set (for example, the clones Xcode creates for parallel testing) are not shown.

A Simulator presented in either host app has its framebuffer consumed by that app's process, so the framebuffer is not available to a process linking `FBSimulatorControl`. Boot without the host app when you need the screen.

### Framebuffers via `IOSurface`

The screen from an iOS Simulator is rendered, regardless of whether there is a `Simulator.app` presenting it in a window. An iOS Simulator can be launched independently of `Simulator.app`, since Simulators are kept alive by `CoreSimulatorService`.

In order for other Applications (mainly `Simulator.app`, but also for video recording within `simctl`) to get the iOS Simulator's Framebuffer for rendering, `CoreSimulator` can access the `IOSurface` of the screen of an iOS Simulator. A Simulator can have many screens, for instance when Simulating CarPlay and the main screen at the same time.

An `IOSurface` is an object that wraps a Framebuffer, with the contents of the Framebuffer being located within GPU memory. This `IOSurface` can be read and inspected across process boundaries. `Simulator.app` uses this `IOSurface` as the backing Framebuffer for its view of an iOS Simulator.

`IOSurface` objects are also cheap to convert into the pixel buffers that video encoding reads, which is how [`FBSimulatorVideo`](../FBSimulatorVideo/README.md) records and streams the Simulator's screen without a per-frame copy.

### Multiple displays

An iPhone Duo has two integrated displays, only one of which is active at a time; a hinge change moves the active display, and settles over a few seconds. [`DisplaySelection`](https://github.com/facebook/idb/blob/main/FBControlCore/Configuration/DisplaySelection.swift) chooses the display that framebuffers, video, screenshots, HID input and accessibility reach:

- `.active`, the default, is resolved when the operation runs, once any transition has settled. A framebuffer follows it to each display that becomes active, as soon as the layout moves there (see below), including after it started on the main screen because the active display was not yet known. Framebuffers and screenshots capture the main display when no active display can be identified; HID input and accessibility fail instead.
- `.display(uniqueID:)` names a display. A framebuffer captures it even while it is inactive; HID input, accessibility and screenshots fail unless it is the active display.
- `.configuration(generation:)` names a configuration read from `displays.configuration()` or `displays.configurations()`, so that coordinates computed against it cannot reach a display that has since changed. Operations fail with `SimulatorDisplayError.changed` once it is replaced, and a framebuffer bound to it ends.
- `.main` is the display with `displayClass` 0, which is the cover display of an iPhone Duo. Framebuffers and screenshots only.

A screenshot result names the identified display it captured through `displayID`. A direct main-screen capture, including the fallback from `.active`, leaves that field nil rather than attributing its pixels to a display resolved separately.

Only `.active` falls back: every other selection fails rather than reaching a display other than the one selected.

#### Switching displays

A hinge change moves the layout to the other display a few seconds before the outgoing display's backlight turns off. The configuration reports this as `.transitioning(incoming:)`, still describing the outgoing displays, and `incoming` names the display the layout moved to, which already draws. HID input, accessibility and screenshots wait for `.settled`, as they act on the display the guest treats as lit. A framebuffer following `.active` moves to `incoming` straight away, so video shows the incoming display rather than the outgoing one going dark, which on an iPhone Duo close lasts about 3 seconds.

`SimulatorVideoStream` prepares for a switch itself. Once a configuration has integrated displays of more than one size, it sets up and warms an encoder for each size it is not showing, and keeps the encoder it switches away from. The first frame after a switch is a keyframe.

A consumer with its own encoder can build the same behaviour from public pieces:

- **A framebuffer per display.** `framebuffer.connect(display: .display(uniqueID:))` gives a framebuffer that stays on its display, active or not, and several can be connected at once, alongside one following `.active`.
- **When to switch.** `displays.configurations()` streams each configuration; `.transitioning(incoming:)` is the earliest moment a switch is safe for frames.
- **What to prepare.** `SimulatorDisplayGeometry.surfacePixelSize` is the size of the `IOSurface` each display's framebuffer hands over, whatever the interface rotation, so an encoder can be set up for a display before switching to it.
- **What a switch needs.** An encoder taken up after a switch should start with a keyframe, since anything it encoded before was never sent.

### HID: `IndigoHID` and `DTUHID`

"Indigo" is a service present in the iOS Simulator that is used inside `Simulator.app` to synthesize "Input Events" that are understood within the iOS Simulator. This service is how clicking on the UI of the `Simulator.app` translates into touches within the iOS Simulator.

This uses "mach" IPC, where data structures are sent over a channel using `mach_msg_send`. These data structures are defined through the "Mach Interface Generator", which get compiled out of the `Simulator.app` binary. As such, `FBSimulatorControl`'s understanding of the layout and values in these data structures [are understood through reverse engineering](https://github.com/facebook/idb/blob/main/PrivateHeaders/SimulatorApp/Indigo.h).

The reverse engineering of this protocol allows `FBSimulatorControl` to expose APIs that send touch events directly to the iOS Simulator without using Accessibility APIs in a UI Test. The combination of video streams and APIs for sending input events allows for the building of applications that expose a remote iOS Simulator.

Newer Xcode versions introduce a second event path: a `dtuhidd` daemon inside the Simulator, which receives events as XPC dictionaries rather than reverse-engineered mach structures. From Xcode 27 the Simulator drops Indigo button and keyboard events and delivers Indigo touch unreliably (the tvOS trackpad still works), on older runtimes as well as new ones, so `FBSimulatorControl` implements HID delivery behind a pluggable transport ([`SimulatorHID`](https://github.com/facebook/idb/blob/main/FBSimulatorControl/HID/SimulatorHID.swift)). The [DTUHID transport](https://github.com/facebook/idb/blob/main/FBSimulatorControl/HID/SimulatorDigitizerHIDTransport.swift) is the default from Xcode 27 and Indigo before it; if `dtuhidd` cannot be reached the error is reported rather than falling back to Indigo. A caller that does not request a transport does not need to know which one is in use.

A DTUHID gesture lives in `dtuhidd` only as long as its connection. When the daemon interrupts the connection mid-gesture, XPC reconnects on the next send but the gesture is gone, so the sample that would continue it fails with `SimulatorHIDError.dtuhidGestureInterrupted` and the next gesture begins afresh.

An operation that fails or is cancelled releases what it still holds. If that release or the drain after it fails too, the operation throws `SimulatorHIDError.cleanupFailed` with both the error that ended it and the cleanup failures; otherwise it rethrows the error that ended it.

### Apple Watch controls

Two Apple Watch controls are DTUHID-only, and both are refused on any other product family.

- **Digital Crown rotation** rides a scroll service of its own, `com.apple.coredevice.feature.remote.hid.scroll`, as an `IndigoScrollEvent` whose `target` is the crown. A rotation is one gesture — began, then a changed event per sample, then ended — carried on `point.y`. The delta is in the guest's scroll units, not degrees or detents, and `SimulatorCrownRotation` keeps it finite, non-zero and bounded. The connection is held for the life of the `SimulatorHID`, because the guest's crown service belongs to the connection and tearing it down before the guest has consumed a turn cancels the turn.
- **The side button** is a Consumer-page usage on the button path. `SimulatorWatchButton` keeps it apart from `SimulatorHIDButton.sideButton`, the Consumer Power usage, and a press is a down followed by an up.

Neither has a known legacy Indigo encoding, so both are refused on the Indigo transport.

### `SimulatorKit.framework`

This is another macOS Framework that is used in iOS Simulator management. This Framework is not installed to the System, it is bundled within Xcode. Instead, this Framework is more used to implement functionality within `Simulator.app`.

For example, this Framework contains some of the `Indigo` client functionality for sending input events.

## Contributing
See the [contributing guide](../.github/CONTRIBUTING.md) for how to help out. There's plenty to work on in the issues!
