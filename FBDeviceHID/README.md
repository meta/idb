# Physical-device HID preparation

This layer prepares a physical-device tap and validates its private runtime. It emits no input and exposes no device command.

## Metadata preparation

Preparation resolves the selected device's exact UUID and normalizes display-point coordinates without private CoreDevice calls. It requires matching device and display metadata, rejects ambiguous identity or unsupported geometry and orientation, and preserves an absent or zero hold duration without adding a delay. Both queries must return successful JSONv5 with the expected command and device selector. The producer version is required diagnostic metadata, not a release allowlist; the loaded frameworks are validated separately.

Details and display queries run concurrently as owned subprocesses with ten-second query waits. Failure or cancellation joins both owned processes before removing their private output directory. Failed subprocess diagnostics include a bounded stderr tail; a secondary directory-removal error is logged without replacing the primary failure. The immutable prepared coordinates have no timestamp expiry. Preparation does not monitor display changes or guarantee that rotation, dimensions, or display configuration remain unchanged after the reads.

## Private runtime and export

The runtime gate precedes private metadata construction. It requires native arm64 macOS 26.6 or newer and CoreDevice/CoreDeviceUtilities 651.13.5 or newer, comparing each framework's Mach-O source version numerically and rejecting missing or malformed metadata. There is no exact OS-build, file-hash or historical-UUID allowlist. Each installed arm64 slice's `LC_SOURCE_VERSION` and `LC_UUID` are read from the same binary snapshot. Every required symbol must resolve from its expected framework, and its loaded source version and UUID must match that snapshot and meet the minimum. An installation replacement cannot lend its version to an already-loaded older image. These checks do not guarantee private-API ABI or behavior compatibility on newer versions. The runtime preflight has a separate ten-second wait bound; cancellation or timeout prevents a successful preflight result.

The private Swift interface is resilient, without invented `Sendable` conformances or raw enum values. Private Swift references and framework linkage must remain weak so unsupported hosts can use unrelated capabilities. Native callers must validate symbols visible through the binary's weak linkage before constructing private metadata; matching files on disk are not sufficient. The stub preserves CoreDevice's install name and its CoreDeviceUtilities re-export. Exported Xcode and SwiftPM builds require the private Swift module and weak stub as well as Buck builds.

Runtime tests exercise production image validation and preflight deadlines. Their event recorder and one-shot gate have no contact-operation or transport dependency. These host tests do not constitute physical input or UI verification.
