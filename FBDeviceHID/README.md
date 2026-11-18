# Physical-device HID preparation

## Private runtime and export

The private Swift interface is resilient, without invented `Sendable` conformances or raw enum values. Private Swift references and framework linkage must remain weak so unsupported hosts can use unrelated capabilities. Native callers must validate symbols visible through the binary's weak linkage before constructing private metadata; matching files on disk are not sufficient. The stub preserves CoreDevice's install name and its CoreDeviceUtilities re-export. Exported Xcode and SwiftPM builds require the private Swift module and weak stub as well as Buck builds.
