# Camera injection

Video injection plays a video file into the camera of the apps running in an
armed iOS simulator, so an app under test sees a recording wherever it would see
the camera. This directory is the guest half: a virtual camera in
`libShimulator-iOS` and its Shimulator `video` handler.

## Why it synthesises the camera

Microphone injection intercepts a stream that already exists. The simulator has
no camera stream: `AVCaptureDevice` enumeration is empty, `FigCaptureSourceCopySources`
fails, and there is no capture daemon or DAL in the runtime. So the shim swizzles
AVFoundation's Objective-C surface and **is** the camera.

| Synthesised | Stands in for |
|---|---|
| `ShimulatorCaptureDevice` (back and front), `ShimulatorCaptureDeviceFormat` | `AVCaptureDevice` and its format |
| `ShimulatorCaptureDeviceInput`, `ShimulatorCaptureInputPort`, `ShimulatorCaptureConnection` | the input and the connection an output reaches |
| `ShimulatorCaptureDiscoverySession`, `ShimulatorCapturePhoto` | discovery and `AVCapturePhoto` |

A session holding the virtual input is driven entirely by the shim, and so is
one with no native input yet: the simulator has no capture server, so a native
commit fails, and AVFoundation would later post its error as a runtime error on
the session even once it holds the virtual camera. Its preset, configuration and
outputs are kept until an input arrives, and replayed natively if that input is
not the camera. Any other session is passed through untouched. Frames are
decoded at the file's own rate, stamped with the host clock, and shaped per
output (format, preset, rotation) in one CoreImage pass.

## Protocol

The `video` capability of the Shimulator protocol (`Protocol/`,
`VideoInjectionProtocol.swift`). The host serves
`/tmp/idb-shimulator-<uid>/<UDID>.video.sock` and sends each process that connects
`{"version":1,"parameters":{"path":<video>,"frontPath":<video>,"loop":<bool>}}`;
`path` plays on the back camera, and on the front one too unless the optional
`frontPath` gives it a video of its own. The process reports
`accepted` (a frame from the video reached one of the app's outputs), `completed`
(a non-looping video played to its end, after which the camera holds its last
frame) or `failed` (unplayable, or it stopped decoding). Disconnecting stops the
injection and returns the camera to its idle placeholder -- a dark frame labelled
"idb camera / no video injected" with a sweeping dot, shown before any injection
so an armed camera still looks live. A process connects only
once it first enumerates a camera, and serves one injection at a time.

The companion serves it for the `inject_video` RPC (`//xplat/idb:idb.proto`,
`InjectVideoMethodHandler`, and `SimulatorVideoInjectionCommands` in
`FBSimulatorCodeInjection`). While an
injection runs, an app idb launches is given `IDB_VIDEO_INJECTION=1` provided
the shim is already in its `DYLD_INSERT_LIBRARIES`, as microphone injection puts
it there for every iPhone and iPad launch. The videos are copied beside the
socket, as `<UDID>.video-back.<ext>` and `<UDID>.video-front.<ext>`, so apps read
the copies and the client may delete its own files; the copies are deleted, and
every connection closed, when the injection ends.

## Cost

AVFoundation, CoreImage, CoreMedia, CoreVideo and Metal are load-time
dependencies of `libShimulator-iOS`, and the swizzles are installed from a
constructor at load -- but only in a process launched with
`IDB_VIDEO_INJECTION=1`. idb loads the shim into every iOS test process it runs,
and without that variable AVFoundation is left exactly as it was: no virtual
camera, no swizzle. That costs nothing measurable: the shim already pulled
AVFoundation in through UIKit and CoreAudio (470 images either way), and 30
launches of an empty process took the same time with and without the camera. The
camera itself (Metal device, CIContext, queues) is created only when an app first
touches it.

## Rules for the shim

Each of these has already been a crash or a hang:

- **A synthesised AVFoundation object needs its private state holder.** It is
  allocated but never initialised by the framework, so `-dealloc` dereferences a
  nil `_internal`. `AdoptAVFoundationInternals` installs an empty one of the right class.
- **A swizzled `init` must stay in the `init` family** (`initShimulatorWithDevice:error:`),
  or ARC returns it autoreleased while AVFoundation consumes a +1. Swift cannot
  write one, so these and the subclasses live in `ShimulatorVideoInjectionAVFoundation.m`; the rest
  of the camera is Swift.
- **`-[AVCaptureSession dealloc]` calls `removeInput:` until `inputs` is empty**,
  so both are swizzled together or it spins forever.
- **Capture delegates are never called on the main queue**: an app blocking the
  main thread for a photo would deadlock.
- **`lock` is taken before a session's state, never inside it**, and nothing is
  decoded or rendered under it.

## What is covered

| Path | Result |
|---|---|
| `AVCaptureVideoDataOutput` | BGRA or 4:2:0 frames; late frames skipped when `alwaysDiscardsLateVideoFrames` |
| `AVCapturePhotoOutput` | JPEG, pixel buffer and `CGImageRepresentation` of the frame; overlapping captures queue |
| `AVCaptureMovieFileOutput` | video-only H.264 `.mov` written to the destination, deleted on failure |
| `AVCaptureVideoPreviewLayer` | live `contents`, `videoGravity` mapped onto `contentsGravity` |
| `metadataOutputRectOfInterestForRect:`, `rectForMetadataOutputRectOfInterest:`, `captureDevicePointOfInterestForPoint:`, `pointForCaptureDevicePointOfInterest:` | between the layer and the normalised native frame, after `videoGravity`, the connection's rotation and mirroring, as on a device |
| `AVCaptureSession.connections` | the virtual outputs' connections once the camera input is added, after any native ones |
| `systemPreferredCamera`, `userPreferredCamera` | the back camera, as `defaultDeviceWithMediaType:` answers |
| `videoMirrored` | a front camera's preview is mirrored and its outputs are not while `automaticallyAdjustsVideoMirroring` is on, as on a device; setting `videoMirrored` then raises, as it does there |

Preview layers are tracked from `setSession:`, since apps bind them before adding the input.

Not yet covered: `AVCaptureMultiCamSession`, depth and metadata outputs,
`transformedMetadataObjectForMetadataObject:`, `AVCaptureDeviceRotationCoordinator`,
audio in recorded movies, an `activeFormat` that follows the preset (it is always
1920x1080), a preview layer's connection in a session's `connections`, and
`recordedDuration`.

## Presets and orientation

Frames come at the camera's size, not the file's: a real device answers a preset
by choosing a sensor format. The file is scaled to fill that frame and
centre-cropped, as Android's E2E camera does, so any clip fills any output.

| preset | native (landscape) frame |
|---|---|
| `High`, `InputPriority` | 1920x1080 |
| `Photo` | 1440x1080 |
| `Medium` / `Low` | 480x360 / 192x144 |
| `352x288`, `640x480`, `iFrame960x540`, `1280x720`, `iFrame1280x720`, `1920x1080`, `3840x2160` | as named |
| anything else | 1920x1080 |

The file is upright in portrait, as a phone is held, after its
`preferredTransform`. The connection's `videoRotationAngle` (clockwise;
`videoOrientation` is the same angle) turns every output, as a video data output
"does output physically rotated video buffers", and a 90 or 270 angle swaps the
frame's width and height. A front camera is mounted the other way up, so its
landscape angles are swapped: as on a device, an app gets the same native frame
from the front camera at `LandscapeLeft` as from the back one at `LandscapeRight`.
A preview layer's connection starts at 90. An output's starts at the native angle
of the camera it reads, 0 for a back camera and 180 for a front one, and follows
the camera until the app sets an angle:

| angle | `videoOrientation` | file's top edge becomes (back) | (front) |
|---|---|---|---|
| 0 (back outputs) | `LandscapeRight` | left | right |
| 90 (preview) | `Portrait` | top | top |
| 180 (front outputs) | `LandscapeLeft` | right | left |
| 270 | `PortraitUpsideDown` | bottom | bottom |

## Validating by hand

```sh
buck2 build fbsource//fbobjc/Tools/idb:libShimulator-iOS fbsource//fbobjc/Tools/idb:CameraFixture-iOS \
  fbsource//fbobjc/Tools/idb:makevideo --show-full-output
makevideo /tmp/in.mov 1280 720 1 ff0000 00ff00 0000ff   # left half the colour, right half white
xcrun simctl --set "$SET" spawn "$UDID" launchctl setenv IDB_VIDEO_INJECTION 1
xcrun simctl --set "$SET" spawn "$UDID" launchctl setenv DYLD_INSERT_LIBRARIES /path/to/libShimulator-iOS.dylib
xcrun simctl --set "$SET" spawn "$UDID" /path/to/CameraFixture watch 30 &
```

(`SIMCTL_CHILD_IDB_VIDEO_INJECTION=1 SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=<dylib>` arms a single spawn instead.) Then
serve the socket, keeping each connection open for as long as the video should play:

```python
import json, os, socket, struct, sys
udid, video = sys.argv[1], sys.argv[2]
path = f"/tmp/idb-shimulator-{os.getuid()}/{udid.replace('-', '').upper()}.video.sock"
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
server = socket.socket(socket.AF_UNIX)
server.bind(path)
server.listen()
request = json.dumps({"version": 1, "parameters": {"path": video, "loop": True}}).encode()  # "frontPath": <video>
connections = []
while True:
    connection, _ = server.accept()
    connections.append(connection)
    connection.sendall(struct.pack(">I", len(request)) + request)
    print(connection.recv(4096)[4:].decode())  # "state":"accepted" once frames flow
```

`CameraFixture` prints `CAMFIXTURE` lines; its header lists the subcommands.
