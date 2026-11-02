![idb logo](website/static/img/idb_logo.jpg)

[![CI](https://github.com/facebook/idb/actions/workflows/ci.yml/badge.svg)](https://github.com/facebook/idb/actions/workflows/ci.yml)
[![Discord](https://img.shields.io/discord/770978552698896394?style=flat-square)](https://discord.gg/SF26Yqw)

The "iOS Development Bridge" or `idb`, is a command line interface for automating iOS Simulators and Devices. It has three main principles:

* *Remote Automation*: `idb` is composed of a "companion" that runs on macOS and a python client that can run anywhere. This enables scenarios such as a "Device Lab" within a Data Center or fanning out shards of test executions to a large pool of iOS Simulators.
* *Simple Primitives*: `idb` exposes granular commands so that sophisticated workflows can be sequenced on top of them. This means you can use `idb` from an IDE or build an automated testing scenario that isn't feasible with default tooling. All of these primitives aim to be consistent across iOS versions and between iOS Simulators and iOS Devices. All the primitives are exposed over a cli, so that it's easy to use for both humans and automation.
* *Exposing missing functionality*: Xcode has a number of features that aren't available outside its user interface. `idb` leverages many of Private Frameworks that are used by Xcode, so that these features can be in GUI-less automated scenarios.

`idb` is built on top of the `FBSimulatorControl` and `FBDeviceControl` macOS Frameworks, contained within this repository. These Frameworks can be used independently of `idb`, however `idb` is likely to provide the simplest install and the most sensible defaults for most users.

`idb` is nearly a pure Swift codebase: the companion and the Frameworks are written in Swift, apart from the XCTest `DTX` layer in `FBXCTestCore`. [The architecture documentation](https://www.fbidb.io/idb/architecture) describes where the migration stands.

A talk from F8 2019 covers the original motivation for `idb`; a [recording is available here](https://developers.facebook.com/videos/2019/reliable-code-at-scale/).

## Quick Start

`idb` is made up of 2 major components, both of which are installed by a single brew formula.

### `idb` companion

Each target (simulator/device) will have a companion process attached allowing `idb` to communicate remotely.

The `idb` companion can be installed via brew or built from [source](https://github.com/facebook/idb)

```
brew tap meta/fb
brew trust meta/fb
brew install meta/fb/idb
```
Current Homebrew refuses formulae from a tap you have not trusted, along with the dependencies they pull in from it. If you tapped `facebook/fb` before GitHub renamed the facebook organization to meta, run `brew update` instead of `brew tap meta/fb`: Homebrew moves the tap to `meta/fb` but drops its trust, so `brew trust meta/fb` is still needed.

Note: Instructions on how to install brew can be found [here](https://brew.sh)

To install the CI build of any commit or pull request, run `./homebrew.py` from a checkout; see [Installing a specific build](https://www.fbidb.io/idb/installation#installing-a-specific-build).

### `idb` client

A cli tool and python client is provided to interact with `idb`.

It is installed alongside the companion by the brew formula above. It can also be installed separately via pip (releases publish to PyPI):

```
pip3 install fb-idb
```
Note: The idb client requires python 3.10 or greater to be installed.

Please refer to [fbidb.io](https://www.fbidb.io/) for detailed installation instructions and a guided tour of idb.

Once installed, just run the list-targets command which will show you all the simulators installed on your system:

```
$ idb list-targets
...
iPhone 16 | 569C0F94-5D53-40D2-AF8F-F4AA5BAA7D5E | Shutdown | simulator | iOS 26.0 | arm64 | No Companion Connected
iPhone 17 | 2A1C6A5A-0C67-46FD-B3F5-3CB42FFB38B5 | Shutdown | simulator | iOS 26.0 | arm64 | No Companion Connected
iPhone 17 Pro | D3CF178F-EF61-4CD3-BB3B-F5ECAD246310 | Shutdown | simulator | iOS 26.0 | arm64 | No Companion Connected
iPhone Air | 74064851-4B98-473A-8110-225202BB86F6 | Shutdown | simulator | iOS 26.0 | arm64 | No Companion Connected
...
```

`list-apps` will show you all the apps installed in a simulator:

```
$ idb list-apps --udid 74064851-4B98-473A-8110-225202BB86F6
com.apple.Maps | Maps | system | arm64 | Not running | Not Debuggable
com.apple.MobileSMS | MobileSMS | system | arm64 | Not running | Not Debuggable
com.apple.mobileslideshow | MobileSlideShow | system | arm64 | Not running | Not Debuggable
com.apple.mobilesafari | MobileSafari | system | arm64 | Not running | Not Debuggable
```

`launch` will launch an application:

```
$ idb launch com.apple.mobilesafari
```

Head over [to the main documentation](https://www.fbidb.io) for more details on what you can do with idb and the full list of commands. There are also instructions on how to [make changes to `idb` including building it from source](https://www.fbidb.io/idb/development).

## Building from Source

### Prerequisites

- **macOS 15+** with **Xcode 26.0+**
- **XcodeGen**: `brew install xcodegen`
- **For idb_companion**: the protobuf compiler
  ```
  brew install protobuf
  ```
  (`build.sh` builds both Swift codegen plugins itself — `protoc-gen-swift` and `protoc-gen-grpc-swift-2` — using the versions and revisions in `Package.resolved`, so the generated code matches the runtime it is generated against.)

### Building

```bash
# Build everything and assemble the runnable distribution
./build.sh build

# Or build a subset: libraries, shims, idb_companion, or a specific library
./build.sh build libraries
./build.sh build library-package   # the libraries as consumers take them; see FBSimulatorControl/README.md
./build.sh build idb_companion
./build.sh build FBControlCore

# All options
./build.sh help
```

The build writes individual products under `Build/Products`, with macOS products under `Build/Products/Release` and simulator products under platform-specific `Release-*` directories. The framework targets are static libraries linked into the executables, so they are not copied into the runtime distribution. A full `./build.sh build` assembles the self-contained distribution at `Build/Distribution`:

```
Build/Distribution/
  idb_companion              # the companion executable
  idb-repl                   # the REPL client
  sim-video                  # the simulator video recorder
  *.bundle                   # SwiftPM resource bundles, when present
  Resources/
    Swift/                   # Swift back-deployment libraries
    libShimulator-iOS.dylib  # the shim injected into simulator processes, the REPL included
    libShimulator-macOS.dylib
    libReplIDB-iOS.dylib     # the IDB API idb-repl injects alongside it
    libReplIDB-macOS.dylib
    SimulatorFrameworkBridge-iOS
    SimulatorFrameworkBridge-tvOS
    SimulatorFrameworkBridge-watchOS
    ReplHost.app
    IDBAPI.swiftinterface
```

The executables resolve their bundled runtime dependencies relative to their own location. Keep `Build/Distribution` together when copying or relocating it.

### Running Tests

```bash
# Run all tests
./build.sh test

# Test a specific framework
./build.sh test FBSimulatorControl
```

### Regenerating Xcode Projects

The Xcode project files are generated from `project.yml` using XcodeGen. To regenerate without building:

```bash
./build.sh generate
```

## Documentation

Find the full documentation for this project at [fbidb.io](https://www.fbidb.io/)

We also have a [public Discord Server that you can join](https://discord.gg/SF26Yqw)

## Contributing

We've released `idb` because it's a big part of how we scale iOS automation at Facebook. We hope that others will be able to benefit from the project where they may have needs that aren't currently serviced by the standard Xcode toolchain.

## Code of Conduct

Facebook has adopted a Code of Conduct that we expect project participants to adhere to. Please [read the full text](https://code.fb.com/codeofconduct) so that you can understand what actions will and will not be tolerated.

## Contributing Guide

Read our [contributing guide](.github/CONTRIBUTING.md) to learn about our development process.

## License

[`idb` is MIT-licensed](LICENSE).

### Updating Swift dependencies

`Package.resolved` is the shared lock for the runtime and both Swift codegen plugins. Keep the exact versions in `Package.swift` and `Companion/project.yml` in agreement with it. `build.sh` stages the lock in the generated Xcode workspace and disables automatic package resolution. It checks the resolved versions, revisions, and repositories after both plugin and Xcode builds.

Codegen uses an incremental SwiftPM build in `Build/Codegen`. Each build validates the lock even when cached plugin binaries exist, and regenerates the protocol sources before XcodeGen expands their source globs. A dependency bump therefore cannot silently reuse older generated sources.

Run `bash tests/build-test.sh "$PWD"` and `python3 -m unittest CI.dependency_lock_tests` from this directory to check the dependency guards without an Apple toolchain. GitHub CI runs both.
