# FBSimulatorVideo

Records and streams the screen of an iOS Simulator. It is the Simulator's video capability, added onto `Simulator` from outside `FBSimulatorControl`: a consumer that does not need video does not link it, and one that does depends on this library alongside `FBSimulatorControl`.

It builds on two other libraries. `FBSimulatorControl` provides the framebuffer it reads, and [`FBVideoCore`](../FBVideoCore/README.md) provides the configuration, command protocols and container writers it produces through.

## From framebuffer to video

`FBSimulatorControl` exposes a booted Simulator's screen as an `IOSurface`-backed `Framebuffer`. An `IOSurface` is cheap to wrap as a `CVPixelBuffer`, the input VideoToolbox encodes from, so `SimulatorVideoStream` encodes the Simulator's screen without copying a bitmap per frame.

- **Cadence.** By default a stream is variable-frame-rate: a frame is pushed only when the framebuffer reports that the Simulator rendered one, so an idle screen costs nothing. A fixed frame rate drives pushes from a drift-corrected clock instead, and skips the deadlines a stall consumed rather than emitting a burst of late frames.
- **Encoding.** H.264 and HEVC are encoded with VideoToolbox, hardware where the host has it. MJPEG, minicap and raw BGRA frames are also available, and the frames are scaled and padded to the configured output dimensions.
- **Overlays.** Bars and shapes rendered by `OverlayRenderer` are composited over each frame, in a margin added around the screen or over it. Updating an overlay pushes a frame even when the screen has not changed. While the Simulator has drawn into the screen without yet reporting the frame, a variable-frame-rate stream holds an overlay update back and pushes it with that frame, rather than encoding a screen the Simulator has not presented.
- **Output.** A stream writes into a `DataConsumer` through the `FBVideoCore` container writers, with timed metadata in the MPEG-TS and fragmented MP4 transports. `SimulatorVideo` records to a file instead, with chapters if asked for: an MP4 or MOV, or a WebM.
- **Audio.** A stopped MP4 or MOV recording can take an AAC track from a WAV file with `addAudio(fromWAV:startingAtHostTime:)`. Each recording reads the host clock (`mach_absolute_time`) as its first frame is pushed, beside the wall clock, so `startedAtHostTime()` puts media time zero on the clock Core Audio stamps the simulator's sound with. The track is placed by the host time the WAV's first frame played, and audio from before the first frame is cut. Like chapters, the audio is written by copying the video through a second writer, and the copy replaces the original.
- **Canvas.** An MP4 or MOV is presented at one size, so a recording into one keeps its first frame's canvas and letterboxes a later screen of another shape (after a rotation, or a switch to another display) into it. A stream, and a recording into a WebM, follow the screen's size instead; Chrome plays such a WebM correctly through each change, and QuickTime cannot open it.

## Using it

The `videoRecording` and `videoStream` command nouns are available on a `Simulator` once this library is imported:

```swift
import FBSimulatorVideo

let recording = try await simulator.videoRecording.start(toFile: "/tmp/screen.mp4")
// ...
let file = try await recording.stop()
```

Two recordings of one `Simulator` can run at once, beside any streams, such as a test that records itself while a harness records the whole run. Each is independent:

- **Its own pipeline.** Each `start` connects a framebuffer of its own, registered with the display under a token of its own, and runs its own encoder and file writer. Stopping one unregisters only its token and finalizes only its file; the other keeps receiving every frame. A start still waiting for the display's surface ends when its task is cancelled.
- **At most two.** Each recording costs an encoder, so a third `start` while two run is refused with an error naming the two files. When a recording starts beside another, the simulator's logger gets one line naming both files, so a slowdown can be traced to it.
- **One file, one recording.** A writer replaces whatever is at its path when its first frame arrives, so `start` refuses, at once and naming the path, a file that another recording started through `videoRecording` in this process is writing. Two spellings of a path name one file when they reach its directory through symbolic links, `/private`, `.` and `..`, or a relative path, when they differ only in Unicode normalization, and, on a volume that ignores case, only in case. A symbolic link at the file's own name is an entry of its own: a writer replaces the link, not the file it points to.

A recording runs, counts and holds its file until `stop()` returns on the handle `start` returned; a second `stop()` returns once the first has finalized the file. Releasing the handle does not stop it. An audio track added to the stopped file rewrites it after that.

A consumer that drives the pipeline itself, for example to composite its own overlays, connects a framebuffer and builds the stream directly with `SimulatorVideoStream.start(framebuffer:configuration:to:logger:)`.

## The recorder session

`Recorder/` holds the session setup and the line-oriented stdin protocol that the `sim-video` tool uses, so other local clients can drive a recording the same way. The protocol is documented in [the `sim-video` README](../Tools/VideoRecorder/README.md).
