# Physical-device HID preparation

## Private runtime and export

The runtime gate precedes private metadata construction. It requires native arm64 macOS 26.6 or newer and CoreDevice/CoreDeviceUtilities 651.13.5 or newer, comparing each framework's Mach-O source version numerically and rejecting missing or malformed metadata. There is no exact OS-build, file-hash or historical-UUID allowlist. Each installed arm64 slice's `LC_SOURCE_VERSION` and `LC_UUID` are read from the same binary snapshot. Every required symbol must resolve from its expected framework, and its loaded source version and UUID must match that snapshot and meet the minimum. An installation replacement cannot lend its version to an already-loaded older image. These checks do not guarantee private-API ABI or behavior compatibility on newer versions. The runtime preflight has a separate ten-second wait bound; cancellation or timeout prevents a successful preflight result.

The private Swift interface is resilient, without invented `Sendable` conformances or raw enum values. Private Swift references and framework linkage must remain weak so unsupported hosts can use unrelated capabilities. Native callers must validate symbols visible through the binary's weak linkage before constructing private metadata; matching files on disk are not sufficient. The stub preserves CoreDevice's install name and its CoreDeviceUtilities re-export. Exported Xcode and SwiftPM builds require the private Swift module and weak stub as well as Buck builds.

Runtime tests exercise production image validation and preflight deadlines. Their event recorder and one-shot gate have no contact-operation or transport dependency. These host tests do not constitute physical input or UI verification.
