# FBControlCore

The base framework of the idb project: `FBSimulatorControl`, `FBDeviceControl` and `FBXCTestCore` are all built on it. It defines the interfaces that make an iOS Simulator and an iOS Device interchangeable to callers, and provides the machinery those frameworks share.

It is written in Swift, apart from a small Objective-C guard that catches exceptions thrown by Apple's private Objective-C API.

## What it provides

- **Targets.** `Target` describes a single iOS Simulator or Device; `Simulator` and `Device` implement it in their respective frameworks, so higher layers can treat a target uniformly regardless of its kind. `TargetSet` is the counterpart for collections of targets.
- **Command protocols.** Functionality is defined as protocols, such as `ApplicationCommands`, implemented separately for Simulators and Devices. Protocols common to both are part of `Target`; target-specific ones are declared on the concrete classes. A capability built in a module of its own is a protocol refining `Target` that the module conforms each target to, so this framework does not have to know it: `VideoTarget`, in `FBVideoCore`, is one. The protocols are Swift, with `async` methods.
- **Configuration values.** Value types such as `ApplicationLaunchConfiguration` gather the arguments to a call, providing defaults instead of long parameter lists.
- **Screenshot results.** `ScreenshotResult` carries encoded pixels and geometry. Its optional `displayID` names the display identified by capture; an unidentified main-screen capture or a target that cannot name its display leaves it nil. An empty reported identity is normalized to nil at result construction. It does not identify an application or certify source.
- **Asynchrony.** Asynchronous work uses Swift Concurrency throughout. `AsyncEvent` signals that something has happened, or failed, to any number of waiters, and `AsyncPolling` waits on a condition against a timeout that says what it was waiting for.
- **IO and processes.** Abstractions for reading and writing between sources and sinks (`DescriptorReader`, `FileWriter`), and for spawning and supervising processes, backed by `libdispatch`.
- **Logging.** `ControlCoreLogger` provides a common logging interface for all of the frameworks.

[The architecture documentation](https://www.fbidb.io/idb/architecture) covers how these pieces fit together in `idb`.
