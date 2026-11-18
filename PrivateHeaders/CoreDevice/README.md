# Reconstructed CoreDevice Swift interface

This declaration-only module describes the private ABI consumed by physical-device
HID. It is not an Apple-distributed Swift interface and is not a compatibility
promise for later framework releases. Runtime minimum-version, symbol-owner
and installed/loaded-image checks cannot establish structural ABI compatibility.
The declarations use library evolution; do not invent frozen layouts, raw enum
values, class constraints or conformances.

## Associated result derivation

The reference inspection used the installed arm64e slices of CoreDevice and
CoreDeviceUtilities 651.13.5 on arm64 macOS 27.2.1. Both versions were read from
Mach-O `LC_SOURCE_VERSION`, not only the bundle property list. The inspected
framework-file SHA-256 hashes were:

- CoreDevice: `554dc30cd9325ca556a58dfdd74215e6088c1c4a277d5fe35ab27480a97b59d9`
- CoreDeviceUtilities: `eef3e1e4e3f61deefc26ea9d1e1180cd552828c6f6ccba15d3f686b3c4462eac`

These are evidence identifiers, not a runtime allowlist.

In CoreDevice, the `__swift5_assocty` record at `0x5db9a0` identifies
`DigitizerHIDCapability : DeviceCapability`. The records named `ProtocolType` and
`ImplType` both point to `__swift5_typeref` at `0x5ae8aa`. Its bytes are
`02 bd ff 09 00 5f 70 00`: an indirect symbolic context reference followed by the
existential suffix `_p`. The signed relative reference at `0x5ae8ab` leads to
`0x64e868`. The Mach-O authenticated fixup at that address resolves to `0x5c7738`,
the `HIDDigitizer` protocol descriptor. Thus both associated types are
`any HIDDigitizer`, rather than a concrete implementation class. The conformance
witness table at `0x65e090` corroborates the two encoded associated references.

The `DeviceCapability` descriptor at `0x5ca144` has no generic signature
requirements and three requirements in this order: `ProtocolType`, `ImplType`,
static `capability`. `DeviceCapabilityProtocol` has the four static getters
`capability`, `identifier`, `identifierSuffix`, `priority`. `HIDDigitizer` has the
base conformance, `send` and `sendBarrier` requirements. Native dispatch thunks
use witness offsets `0x10` and `0x18` for the latter two.


The generic factory symbol only says that its return type is `C.ProtocolType`.
It cannot establish the concrete associated type. Its method descriptor at
`0x5c5464` and the `RemoteDevice` class dispatch slot at `0x65b890` lead to async
descriptor `0x573588`, whose relative function pointer leads to `0x17dc28`.
The implementation calls `swift_getAssociatedTypeWitness` for `ProtocolType` at
`0x17de2c`, then uses the resulting type metadata and value witness table to size
storage. The return path at `0x17ea58`–`0x17ea84` writes into the caller's result
address with that value witness table. A wrong caller-side associated type can
therefore corrupt result storage before any later cast.


## Rechecking a framework update

Use a new scratch directory and inspect files without loading the frameworks:

1. Record the OS, actual Mach-O architecture, file hashes, `LC_UUID`,
   `LC_SOURCE_VERSION` and reexports using `file`, `shasum -a 256` and
   `xcrun llvm-objdump --macho --private-headers`. Inspect both frameworks;
   CoreDevice reexports CoreDeviceUtilities. An arm64 host may have arm64e files.
2. Capture `xcrun nm --arch=<slice> -m <binary>` and pipe a copy through
   `xcrun swift-demangle`. These locate symbols, not layouts.
3. Decode `__swift5_assocty` descriptors: two signed relative type references,
   record count and record size, then each associated name/substituted-type pair.
   Follow both aliases through `__swift5_typeref`. Resolve indirect references
   with `xcrun dyld_info -fixups <binary>`; raw authenticated pointer bits are
   not plain addresses. `dyld_info -section __TEXT __swift5_assocty` supplies an
   independent raw-byte view. Verify the actual target protocol descriptor.
4. Inspect protocol signature requirements and ordered requirement records,
   conformance witnesses, and factory dispatch/return paths with
   `xcrun dyld_info -disassemble <binary>` or bounded `llvm-objdump` disassembly.
   Rediscover addresses for changed binaries; the addresses above apply only to
   the reference files. Missing reflection data requires another derivation,
   not accepting matching symbol names as a substitute.
5. Compile the actual consuming library with its optimized shipping settings.
   Inspect its SIL or objects to ensure the generic result remains dependent on
   associated metadata and the conditional cast really survives optimization.
   A no-inline annotation alone is not proof: generic specialization can still
   remove a redundant cast. Include the new weak imports in the stub and runtime
   catalogue only when the compiled output requires them.
6. Check hashes again to ensure the files did not change during inspection.
   Record separately which runtime behavior, if any, was tested. Static matching
   metadata does not prove successful device calls or remote HID effects.

## Prelink weak imports

Checking linked-image imports is complementary to the raw-input check. A linker
`-weak_library` option can turn strong compiler references into weak final-image
references, so the linked image cannot prove source/compiler weakness.

The prelink check obtains the full stub export set with
`nm --export-symbols --add-inlinedinfo`, including the inlined Utilities stub,
and intersects it with `nm --undefined-only --no-weak --format=just-symbols` for
the actual library archive before linking. Any intersection is an error. Missing
inputs, nm failures, malformed output and an empty export set are errors too.
Do not narrow the check to symbols beginning with `$s10CoreDevice`: associated
requirements can begin with names such as `$s12ProtocolType10CoreDevice`.
