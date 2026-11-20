# FBSimulatorCodeInjection

Injects Swift into a process on an iOS Simulator. It is the Simulator's REPL capability, added onto `Simulator` from outside `FBSimulatorControl`: a consumer that does not inject code does not link it, and one that does depends on this library.

`idb-repl` is one client: the companion's `repl` method uses this library for everything it does inside the Simulator, and adds only the gRPC stream in front.

## Using it

`simulator.codeInjection` is available on a `Simulator` once this library is imported. `inject(into:)` starts a host with the shim injected and returns a `CodeInjectionSession`, which runs compiled dylibs inside it:

```swift
import FBSimulatorCodeInjection

let session = try await simulator.codeInjection.inject(into: .application(bundleID: "com.example.App"))
let output = try await session.execute(dylibAtPath: "/tmp/payload.dylib", symbol: "payload_entry")
try await session.close()
```

- **Targets.** `.application(bundleID:reattach:)` launches an app with the shim injected, or with `reattach` joins one still serving a session; the app outlives the session. `.simulator` runs the shim in the Simulator's guest bridge, and `.logicTestBundle(path:)` in a logic-test bundle; both end with the session.
- **The entry point.** The host loads the dylib and calls `symbol`, an exported function that takes no arguments and returns a `malloc`'d C string, which the host frees. `execute` returns that string, or throws `CodeInjectionError.executionFailed` when the dylib does not load or the code reports failure.
- **Host commands.** Injected code can send bytes back to the session while it runs. `execute`'s optional `hostCommands` handler answers them; without one, each is refused. The handler is `@Sendable` because it crosses the socket's I/O queue and a Swift task; mutable captured state belongs behind synchronization or on an actor.
- **Additional libraries.** `additionalLibraries` are loaded into the host alongside the shim before any code is injected, so injected code can call into them. `idb-repl` uses this for the idb command API.
- **The shim.** `.bundled`, the default, is the shim this library carries; `shim: .path(...)` supplies another. `launchEnvironment(forApplication:)` is the environment that arms an ordinary app launch the same way, so a later `inject(into: .application(bundleID:reattach: true))` joins it.

## Microphone injection

The library's second injection mechanism plays audio into a Simulator app's microphone input, through the same shim's audio interposer rather than its REPL. `simulator.audioInjection.appLaunchEnvironment(_:)` arms an app launch by inserting `libShimulator-iOS.dylib` into it, and `inject(from:)` then plays a 16-bit PCM WAV file into every armed app that is recording, returning when playback finishes. Failures are `AudioInjectionError`s. An app that is already running cannot be armed without a relaunch. So that the insertion keeps any libraries the Simulator's launchd would have inserted, arming reads launchd's `DYLD_INSERT_LIBRARIES` for each launch: through CoreSimulator, which starts no process in the Simulator, or with the runtime's `launchctl` when the companion's environment sets `IDB_LAUNCHD_GETENV=launchctl`.

## Audio capture

The same shim keeps what Simulator apps play. `appLaunchEnvironment(_:)` arms every launch it prepares with `IDB_AUDIO_CAPTURE=1`, and an armed app captures nothing until a capture starts. `simulator.audioCapture.start()` serves the shim's `audio-capture` capability with a private directory and returns an `AudioCaptureSession`. Each armed process that plays joins the capture and writes what it renders into one file there. `stop(writingMixTo:)` lets the processes go and waits up to 2 seconds for each one still running to write what it has left; one still writing after that is named in `failures`, and what it had written is mixed. It then mixes every file into one two-channel, 32-bit float WAV and returns a `CapturedAudio`. Failures are `AudioCaptureError`s.

The mix is laid on the host clock that the simulator's video is stamped against: `startHostTime` is when its first frame played, in `mach_absolute_time` ticks. Within a stream, the mix holds exactly the samples the app rendered. Frames a process dropped leave silence where they would have played. A stream whose device clock drifts more than 10 ms from the host clock is moved back onto it, and `realignments` counts each move. A process that exited during the capture keeps what it wrote, with no count of dropped frames. What a process played at a rate other than the mix's, or at a rate no audio device runs at, is counted in `unmixedFrames` and left out. A capture file that puts audio at a time that is not a number, or past what one WAV file can hold, fails the mix with an `AudioCaptureError`.

## Camera injection

The third plays a video into the cameras of Simulator apps, through the same shim's virtual camera. `simulator.videoInjection.inject(back:front:loop:onUpdate:)` serves the shim's `video` capability: it copies the videos beside the Simulator's socket, reports the processes whose cameras are showing them, and returns once one has shown the whole video, or runs until cancelled with `loop`. While it runs, `appLaunchEnvironment(_:)` arms an app launch that microphone injection has already given the shim, so apply it after `audioInjection`'s. Failures are `VideoInjectionError`s. Ending the injection returns every armed camera to its idle pattern.

## How it works

The shim, `libShimulator` (the one idb injects for XCTest and audio injection too, each part inert unless armed), is this library's resource: a bundle that links the library carries it, and the library finds it there or in the `Resources/` directory beside a standalone binary. It is injected into the host with `DYLD_INSERT_LIBRARIES` for an app, loaded by the guest bridge for the Simulator, and injected by the logic-test runner for a test bundle, which is why this library depends on [`FBSimulatorXCTest`](../FBSimulatorXCTest/README.md).

Inside the host, the shim binds a Unix-domain control socket and serves one connection at a time. On connect it greets the session with the host's session id and the interfaces it generated; each execute loads a dylib and calls its entry point, and a host command the injected code sends while it runs travels back over the same socket and waits for its answer. An app's socket path is derived from the Simulator and the bundle id, so a later session can find an app still serving one.

## Seeing it work

`FBSimulatorCodeInjectionSmokeTests` drives the library the way a consumer outside idb does, against a booted Simulator and through its public API alone. It injects a small prebuilt Swift payload, [`CodeInjectionPayload.swift`](../Fixtures/Source/CodeInjectionPayload/CodeInjectionPayload.swift), whose entry points read state only code inside the process can know: the Simulator the process runs on and its bundle identifier, how many views Settings' windows hold, and a count that a later session reattaching to the app sees continue. The tests are [`CodeInjectionSmokeTests.swift`](../FBSimulatorCodeInjectionTests/Tests/Smoke/CodeInjectionSmokeTests.swift).

[`AudioCaptureSmokeTests.swift`](../FBSimulatorCodeInjectionTests/Tests/Smoke/AudioCaptureSmokeTests.swift) records Settings' screen and sound together while the payload flashes the screen green and plays a click at the same moment, eight times. It checks that the capture keeps each click at the level the app played it, and that each click in the recording's audio track lands within 45 ms of its flash.

Compiling the code to inject is the caller's: `idb-repl` compiles it on the client side with `ReplCompiler` and sends the dylib to the companion, which writes it where the Simulator can read it and executes it through this library.
