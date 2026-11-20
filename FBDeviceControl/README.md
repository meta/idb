# `FBDeviceControl`

A sister-framework to [`FBSimulatorControl`](https://github.com/facebook/idb/tree/main/FBSimulatorControl) for iOS Devices.

Like `FBSimulatorControl`, `FBDeviceControl` is primarily an implementation detail of `idb`, and `idb` is the easiest way to use what it implements. It is also built to be linked directly, mainly by native macOS applications that embed Device automation in-process, or by consumers that need finer-grained control than the `idb` cli exposes. The same trade-off applies. The `idb` cli and its gRPC interface are the project's compatibility boundary; the framework's own APIs change more freely with the implementation.

## How iOS Device control works

iOS Device access from macOS goes through a stack of private frameworks and device-side services. The sections below describe what each one is and how `FBDeviceControl` drives it.

### `MobileDevice.framework`

`MobileDevice.framework` is a System Framework for macOS. Its default location is at `/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice`. This is a Private Framework, there is no Apple-provided documentation for it. Most of its API is of the CoreFoundation style, which means that most of its surface is made up of plain C symbols with `CF` objects passed in or out. As such, integrating it is relatively simple, since `CF` objects are often [Toll-Free Bridged to Objective-C](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFDesignConcepts/Articles/tollFreeBridgedTypes.html) and so reachable from Swift too. `FBDeviceControl` is written in Swift; the `MobileDevice.framework` call tables are declared in a single C header.

At a first glance, this Framework is difficult to deal with since Private APIs are typically easier to work with if they export Objective-C classes. However, most of the usual patterns around how `CoreFoundation` APIs do apply. `MobileDevice.framework` is used extensively across Apple's macOS Applications that interact with iOS Devices (Finder/iTunes, Xcode, Accessibility Inspector, Apple Configurator 2, Photos). If an Application uses an iOS Device on macOS, it is extremely likely to leverage `MobileDevice.framework`.

This wealth of "clients" of `MobileDevice.framework` has made it possible to understand how each of the API calls work in terms of their inputs and outputs. As a result, [there's a header that defines all of the calls that `FBDeviceControl` uses](https://github.com/facebook/idb/blob/main/PrivateHeaders/MobileDeviceAPI/AMDefines.h).

`FBDeviceControl` aims to use these APIs as far as possible, `MobileDevice.framework` is assumed to be the "canonical" way to interact with iOS Devices on macOS. The `libimobiledevice` project is a [re-implementation of `MobileDevice.framework` that runs on different host operating systems](https://libimobiledevice.org). There's also a range of other projects that use `MobileDevice.framework` including [`SDMMobileDevice`](https://github.com/samdmarshall/SDMMobileDevice/blob/main/SDM_MD_Tests/MobileDevice.h), [`MobileDevice`](https://github.com/mountainstorm/MobileDevice) and [`pymobiledevice`](https://github.com/iOSForensics/pymobiledevice) and more.

There are some exceptions to the level of support for iOS Device operations within `MobileDevice.framework`; some functionality is provided via Xcode itself. This means that some device operations will be fully functional without Xcode installed (and `xcode-select`'ed), but some functionality is dependent on the presence of an Xcode on the host. Typically the functionality that requires Xcode, is only available through Xcode to begin with. `FBDeviceControl` will attempt to defer the loading of Xcode specific functionality until it is used in order to prevent failure for when Xcode is not required. For example if iOS Device listing is only used on a host without Xcode, the device listing functionality will still work.

### `AMDevice`

`AMDevice` is a CF type defined in `MobileDevice.framework`. It is the object that represents a single iOS Device attached to the host. All functions on an `AMDevice` start with the prefix `AMDevice` and typically take an `AMDevice` as the first argument. An `AMDevice` will only be present if the device is both booted and attached to the host. It cannot be in DFU or Restore mode.

To operate on an `AMDevice`, the phone must "trust" the host. You might recognize this as the ["Trust Dialog" that appears when connecting an iOS Device to a Mac](https://support.apple.com/en-gb/HT202778). Most calls will fail if this trust exchange has not been performed. The Mac maintains a local store of the cryptographic components that are used as part of this trust exchange. This local store means that an iOS Device will not constantly require trust to be authorized every time that the iOS Device is connected to the same host. If this process did not take place, then it would be completely infeasible for iOS Devices to be used in a Continuous Integration environment.

Since this is such an important component of how to interact with iOS Devices, it is backed by the [`MobileDevice`](https://github.com/facebook/idb/blob/main/FBDeviceControl/Management/MobileDevice.swift) class.

The process of discovering devices is asynchronous, which means that fetching the list of `AMDevice`s at a snapshot in time is going to be unreliable. `FBDeviceControl` instead uses an API within `MobileDevice.framework` [for receiving an `AMDevice` instance every time there is a state change](https://github.com/facebook/idb/blob/main/FBDeviceControl/Management/AMDeviceManager.swift) in the availability of `AMDevice` instances. This property is also true of Apple's tools that build on top of `MobileDevice.framework`; [`xcodebuild` has a `-destination-timeout` parameter](https://mokacoding.com/blog/xcodebuild-destination-options/) and Apple Configurator's `cfgutil` has a `--timeout` parameter since device discovery is delivered asynchronously. You might never notice this in Xcode's "Devices and Simulators" window, but it is still there too.

### `AMRestorableDevice`

`AMRestorableDevice` is also part of `MobileDevice.framework`, it represents **any** iOS Device that is attached to the host and powered on. This includes iOS Devices that are booting, booted or in DFU/Restore mode.

This API is extremely limited and only exists to describe devices and perform some actions that are only relevant for devices that are not yet in a booted state. This is used to move a booted device to a DFU/Restore state and back out again. It is useful for understanding why a device that appears to be connected may not be represented by an `AMDevice` instance.

This is why `FBDeviceControl` can represent a single `Device` instance to be backed by either or both of an `AMDevice`/`AMRestorableDevice`, for the sake of full observability into connected iOS Devices. `Device` instances will also fail appropriately, for instance when attempting to install an Application to an iOS Device that is in DFU/Restore mode.

### `AMDServiceConnection`

This is another CoreFoundation type that represents a connection to a "lockdown service". In order to get basically anything done on an iOS Device, a connection to service running on the iOS Device is required. There are a huge range of these services for a variety of cases. For example `com.apple.syslog_relay` is a lockdown service that is used for relaying system logs from the iOS Device to the attached host. You might have seen this used in practice within the "Simulators and Devices" window within Xcode. Connections are created via the `AMDeviceSecureStartService` call to an `AMDevice`, returning an `AMDServiceConnection` type.

There are a number of function calls relevant to this type, dealing with sending and receiving binary data over the connection as if it was a file descriptor. `AMDServiceConnection` can optionally contain a "secure context", which is cryptographic information required for sending data over a TLS'd connection. This is why it is important to use `AMDServiceConnection(Send|Receive)` instead of raw `read`/`write` syscalls, sending unencrypted information over an encrypted transport will mean that the receiving side is incapable of reading the same data. The presence of a "secure context" can be detected at runtime by inspecting the connection value. In more recent iOS versions, some [services start requiring usage of encrypted IO](https://github.com/facebook/idb/commit/ccff041579475e184695b2cefdc952211dbd6342#diff-7147fc58258b69f4ceb58490a56c16ef795741731f0aed05516b44d397d1e4af) so detection and usage of these calls is very important.

It is important to stress that this type is just a "Transport" rather than a "Protocol". Each "lockdown service" may have it's own very different binary protocol for sending and receiving data. In the simple case of `com.apple.syslog_relay`, the service just repeatedly sends text over the connection. Other protocols, for instance those used by Instruments are far more complicated. There is no single Protocol that is used by all lockdown services.

There is one exception to this, the ["Plist Protocol"](https://github.com/facebook/idb/blob/main/FBDeviceControl/Services/LockdownServiceConnection.swift). This is implemented in `AMDServiceConnection(Send|Receive)Message` calls. This is common across a range of services, such as the screenshot service and SpringBoard service. It writes a length header followed by a binary plist, on both the send and receive sides.

### `AFC`: "Apple File Connection"

`AFC` is also common throughout the `MobileDevice.framework` API. This is a set of APIs for file manipulation on iOS Devices. It is another example of a protocol that wraps an `AMDServiceConnection` transport. It has a number of functions for dealing with reading, writing, listing directories, moving, copying and deleting files. These operations are performed on the `AFCConnection` type.

On non-jailbroken devices, there is no way of getting an `AFC` connection for the entire root filesystem of the Device. Instead, there are different lockdown services corresponding to various containers or sandboxes within the iPhone's operating system. Access to Photos/Media (`com.apple.afc`), Application Sandboxes (`AMDeviceCreateHouseArrestService`) and crash logs (`com.apple.crashreportcopymobile`) are all examples of `AFC` services.

### Developer Disk Images

Whilst iOS by default has a number of different lockdown services provided within the base iOS image, not all of the functionality that is available within Xcode is implemented from services in the base OS. In order to augment the iOS Device with additional functionality to an attached macOS host, [Xcode bundles a "Developer Disk Image"](https://github.com/facebook/idb/blob/main/FBDeviceControl/Utility/DeveloperDiskImage.swift).

This is a regular `.dmg` file, which can be opened on macOS. Within this disk image is a number of executables, libraries and `plist`s describing the lockdown services that get added to the iOS Device upon mounting them on the device. `FBDeviceControl` provides an API for manipulating the [disk image manipulation functions in `MobileDevice.framework`](https://github.com/facebook/idb/blob/main/FBDeviceControl/Commands/DeviceDeveloperDiskImageCommands.swift). It is not possible to mount arbitrary disk image on an iOS Device as every disk image and it's binaries are signed by Apple, only disk images that have genuine Apple signing are allowed to be mounted. There's some evidence within `MobileDevice.framework` to suggest that Apple uses these Disk Images internally for developing iOS itself.
The "Developer Disk Image"s may be different for each major/minor iOS version. This is presumably because the lockdown services interact with APIs on the device that can change in iOS versions. The services that are contained within the Developer Disk Image are associated with functionality that is specific to Xcode, Instruments and Accessibility Inspector. The [usage of and availability of these services can change over Xcode versions](https://github.com/facebook/idb/commit/5b4415a4fa20a49e03f7596cf5fc296efd25df42), so there may be differences in the implementation of clients depending on the protocol version of the service that the client is communicating with.

#### Manipulating Disk Images

Any `FBDeviceControl` functionality that depends on a service provided by a "Developer Disk Image" will implicitly search for and subsequently mount the most appropriate disk image for the attached iOS device. `idb` also provides ways of manually managing the mounting of these disk images through the "disk image container" of file commands:

```
# List all of the available disk images that are present within the current Xcode, as well as the current mounted image/s (if present).
# No images are mounted as the "mounted" path is empty.
$ idb file ls --disk-images .
15.0/DeveloperDiskImage.dmg
12.1/DeveloperDiskImage.dmg
10.0/DeveloperDiskImage.dmg
9.2/DeveloperDiskImage.dmg
9.1/DeveloperDiskImage.dmg
14.2/DeveloperDiskImage.dmg
13.4/DeveloperDiskImage.dmg
11.3/DeveloperDiskImage.dmg
13.0/DeveloperDiskImage.dmg
12.2/DeveloperDiskImage.dmg
10.1/DeveloperDiskImage.dmg
13.1/DeveloperDiskImage.dmg
11.0/DeveloperDiskImage.dmg
14.3/DeveloperDiskImage.dmg
13.5/DeveloperDiskImage.dmg
11.4/DeveloperDiskImage.dmg
12.3/DeveloperDiskImage.dmg
10.2/DeveloperDiskImage.dmg
14.0/DeveloperDiskImage.dmg
13.2/DeveloperDiskImage.dmg
11.1/DeveloperDiskImage.dmg
14.4/DeveloperDiskImage.dmg
13.6/DeveloperDiskImage.dmg
12.0/DeveloperDiskImage.dmg
14.5/DeveloperDiskImage.dmg
12.4/DeveloperDiskImage.dmg
10.3/DeveloperDiskImage.dmg
14.1/DeveloperDiskImage.dmg
11.2/DeveloperDiskImage.dmg
13.3/DeveloperDiskImage.dmg
9.0/DeveloperDiskImage.dmg
9.3/DeveloperDiskImage.dmg
13.7/DeveloperDiskImage.dmg

$ idb file ls --disk-images mounted

# Mounting for the current iOS Version of the attached device (iOS 15.0 succeeds).
$ idb file mv --disk-images 15.0/DeveloperDiskImage.dmg mounted

# Now we can see that the image is mounted.
$ idb file ls --disk-images mounted
15.0/DeveloperDiskImage.dmg

# Unmount the disk image by rm'ing it. The disk image is kept intact on the host, but is unmounted from the device.
$ idb file rm --disk-images mounted/15.0/DeveloperDiskImage.dmg
$ idb file ls --disk-images mounted
```

### Instruments Service

The "Instruments Service", which is a service within the "Developer Disk Image" is a very important one with respect to iOS Device automation. Since `Instruments.app` and the `instruments` commandline offers a lot of functionality for launching and profiling Applications and iOS Devices, it is integral to tasks such as app launching and process listing on iOS Devices.

The client-side implementation of this protocol is provided via `DTXConnectionServices`, with a [provisional re-implementation within `FBDeviceControl`](https://github.com/facebook/idb/blob/main/FBDeviceControl/Services/InstrumentsClient.swift). There are more details about the makeup of this protocol [within the `ios_instruments_client` project](https://github.com/troybowman/ios_instruments_client).

### CoreDevice and `devicectl`

From iOS 17, the developer services, the Instruments Service and the screenshot service among them, live on a personalized developer disk image that is reached through CoreDevice rather than lockdown. On those devices `FBDeviceControl` launches applications, kills processes and takes screenshots by running `xcrun devicectl`, once per operation, and reports `devicectl`'s own error output when it fails. Each run is bounded, and is stopped when its caller is cancelled, except a kill, which runs to completion within its bound so that a stop already asked for is carried out; a run that times out reports the device's connection state as CoreDevice sees it. Devices before iOS 17 use the lockdown services described above.

### Video Encoding

One of the key features of `FBDeviceControl` is the ability to stream the iPhone's screen to the host over USB. You might be familiar with this within QuickTime's "Screen Recording" feature, where you can record video from a connected iOS Device to an `.mp4` file on your Mac.

Access to this [is provided via `AVFoundation`](https://github.com/facebook/idb/blob/main/FBDeviceControl/Video/DeviceVideo.swift) as a "Capture Device". Usage of "Capture Devices" on macOS also requires that the hosting process (The process using `FBDeviceControl`) has system-level permissions for this on more recent versions of macOS. With a Capture Device for the iOS Device screen, it is then possible to create a "Capture Session" with the device. A "Capture Session" can then be established, with relevant configuration so that frames are received in the most optimal format for the consumer. `FBDeviceControl` receives frame samples from the device and these samples are either re-encoded or not before being passed on to a stream of data.

`FBDeviceControl` supports writing to an `mp4` video file or as a stream of encoded data. For streams of data, these can be passed to other Applications for cases like webRTC or HTTP Live-Streaming.

### Debugging Applications

`idb` (via `FBDeviceControl`) has support for launching a `debugserver` on an iOS Device. This enables debugging Apps on iOS Devices, without having to run via Xcode. There are some important considerations in terms of what is possible:

- Only `lldb` may be used as the debugger client.
- Only "Developer Signed" Applications may be debugged. Debugging Enterprise signed or App Store Apps is not supported or allowed by iOS.
- Attaching to an already-launched Application is not supported or allowed by iOS. Debugged Applications must be launched by the debugger.

Debugging an app on an iOS Device isn't quite as simple as an `lldb` one-liner. However, the only process that changes is how to start a debugging session. The process for a device is as follows:

1. The Application to debug is installed on the iOS Device. A copy of the Application is also present/saved on the host attached to the device. The copy of the App is required on the host as this is needed for `lldb` to be able to symbolicate symbols within the debugged app.
2. [A Developer Disk Image](#developer-disk-images) for the current device is mounted. This is required as the `debugserver` lockdown service is contained within the Developer Disk Image.
3. The [`debugserver` service is started via lockdown](https://github.com/facebook/idb/blob/main/FBDeviceControl/Commands/DeviceDebugServerCommands.swift). This results in a bi-directional socket stream that `lldb` can talk to. This is a [remote debugging server, using the gdb protocol](https://lldb.llvm.org/use/remote.html).
4. The `debugserver` service must be made accessible to `lldb`. This is done by wrapping the `debugserver` connection within a socket, so that it can be connected to outside of the process that obtained the `debugserver` socket.
5. `lldb` is started and then connects to the `debugserver` via the exposed socket. A series of commands are sent to `lldb` so that it understands how to connect to the remote debugserver and how to talk to it.
6. `lldb` can now launch and debug the application.

#### A "debuggable app"

Aside from the previously-mentioned requirement that an App is only debuggable if it is "Developer Signed", there is an additional constraint around App debuggability; a copy of the Application must be persisted on the host attached to the device. This is required so that `lldb` has a local copy of the Application available to it for the purpose of symbolication.

`idb` can do this via the `--make-debuggable` flag upon an `idb install`:

```
# Install an app, also persisting it to disk so that idb can later find it when launching a debugserver
$ idb install --make-debuggable /path/to/SomeApp.app
```

You can also confirm whether an app is debuggable or not in the output of `idb list-apps`:

```
$ idb list-apps | grep SomeApp
com.foo.SomeApp | SomeApp | user_development | no archs available | Unknown | Debuggable | pid=None
```

If the application is listed as "Debuggable" then a `debugserver` can be started against it.

#### Starting a `debugserver`

A `debugserver` can then be started for any "Debuggable" App. This is done with the `idb debugserver` command.

```
# Start the debugserver, a list of bootstrapping commands are returned on stdout
$ idb debugserver start com.foo.SomeApp
platform select remote-ios --sysroot '/Users/Someone/Library/Developer/Xcode/iOS DeviceSupport/15.2.1 (19C63) arm64e/Symbols'
target create '/private/tmp/idb-applications/com.foo.SomeApp/SomeApp.app'
script lldb.target.modules[0].SetPlatformFileSpec(lldb.SBFileSpec("/private/var/containers/Bundle/Application/64B4DDB3-1049-458C-AA0B-F56AF4DCF0E0/SomeApp.app"))
process connect connect://localhost:10881
```

The bootstrapping commands returned can then be used to initialize a debug session via `lldb`.

#### Bootstrapping via `lldb`

```
# Start lldb and pass the bootstrapping commands from above
$ lldb
(lldb) platform select remote-ios --sysroot '/Users/Someone/Library/Developer/Xcode/iOS DeviceSupport/15.2.1 (19C63) arm64e/Symbols'
  Platform: remote-ios
 Connected: no
  SDK Path: "/Users/Someone/Library/Developer/Xcode/iOS DeviceSupport/15.2.1 (19C63) arm64e/Symbols"
(lldb) target create '/private/tmp/idb-applications/com.foo.SomeApp/SomeApp.app'
script lldb.target.modules[0].SetPlatformFileSpec(lldb.SBFileSpec("/private/var/containers/Bundle/Application/64B4DDB3-1049-458C-AA0B-F56AF4DCF0E0/SomeApp.app"))Current executable set to '/private/tmp/idb-applications/com.foo.SomeApp/SomeApp.app' (arm64).
(lldb) script lldb.target.modules[0].SetPlatformFileSpec(lldb.SBFileSpec("/private/var/containers/Bundle/Application/64B4DDB3-1049-458C-AA0B-F56AF4DCF0E0/SomeApp.app"))
True
(lldb) process connect connect://localhost:10881
(lldb) r
Process 10416 launched: '/private/tmp/idb-applications/com.foo.SomeApp/SomeApp.app/SomeApp' (arm64)
```

Upon `process connect` completing, the `lldb` will then be attached to the remote `debugserver`. The app will be in a ready state, but not launched; launching can be done with the `run` command in `lldb`.
At this point `lldb` can be used as a regular debugger, there's some [good documentation about how to use `lldb` via its command prompt in `lldb`'s documentation](https://lldb.llvm.org/use/map.html). One important note is that you can only have one debug session with a launched debugserver. To start a new debug session after `process connect`, the debugserver needs to be re-started via `idb debugserver stop` and subsequently running `idb debugserver start` again.
