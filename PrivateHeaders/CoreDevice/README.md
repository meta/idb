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

For `ButtonHIDCapability`, the associated-type record at `0x5db980` names both
aliases at `0x5ae87e`; the symbolic reference leads through `0x64e858` to the
`HIDButton` descriptor at `0x5c76f4`. Both aliases are `any HIDButton`.

The generic factory symbol only says that its return type is `C.ProtocolType`.
It cannot establish the concrete associated type. Its method descriptor at
`0x5c5464` and the `RemoteDevice` class dispatch slot at `0x65b890` lead to async
descriptor `0x573588`, whose relative function pointer leads to `0x17dc28`.
The implementation calls `swift_getAssociatedTypeWitness` for `ProtocolType` at
`0x17de2c`, then uses the resulting type metadata and value witness table to size
storage. The return path at `0x17ea58`–`0x17ea84` writes into the caller's result
address with that value witness table. A wrong caller-side associated type can
therefore corrupt result storage before any later cast.

The transport's checked generic factory keeps the factory result as
`C.ProtocolType` until its conditional conversion to the requested capability protocol.
The small boundary is both no-inline and optimization-disabled: whole-module
`-O` otherwise specializes away the conditional cast even with no-inline alone.
It rejects a mismatched returned implementation before publication to transport
state. This check is defense in depth: it is not recovery from arbitrary private
ABI corruption, and requires a correct generic factory/protocol declaration.

## Display monitoring derivation

The same reference file hashes establish the display capability and value ABI.
The `DisplayInfoCapability` associated-type record at `0x5dbc00` gives both
aliases typeref `0x5ab4e8`; its indirect reference resolves through `0x64e150`
to `DisplayInfoProtocol` descriptor `0x5c7e48`, followed by existential `_p`.
The protocol's requirements are its base conformance, async `displayInfo` getter
and async-throwing `displayInfoUpdates()` method, in that order.

The getter is async **and throwing**. Its requirement flags alone establish only
async. The actual witness table at `0x635fc8`, slot `+0x10`, resolves to async
descriptor `0x57c8e0` and witness `0x2c0a28`. That witness calls descriptor
`0x573338` (entry `0x11aa5c`) with continuation `0x2b17e4`. The continuation saves
and tests returned error register `x20` at `0x2b188c` and `0x2b1894`. Success
resumes the caller with zero; failure follows `0x2b1928` to `0x295d68`, reloads
the saved error at `0x295dbc`, and resumes the caller without catching it.
The concrete getter at `0x2bf910` independently uses the same error propagation.
The declaration is complete even though the stream-first consumer does not call
this getter; no misdispatch from the earlier omission was demonstrated.

CoreDeviceUtilities contains `DisplayInfo`, `Display`, `OrientationInfo`,
`DeviceOrientation`, and `Display.DisplayType` under the CoreDevice module.
Their nominal descriptors are respectively `0x4eae50`, `0x4eada8`, `0x4e6c3c`,
`0x4e6c04`, and `0x4eadc4`. Native metadata accessors and authenticated value
witnesses establish sizes/strides of 13/16, 328/328, 3/3, 1/1, and 1/1 bytes.
The structs contain four, twenty-two, and three stored fields, not just the
exposed getter subset. Keep them opaque and let native metadata own their layout.

Reflection and native getter bodies agree on the consumed fields: an array of
`Display`, optional `OrientationInfo`, UInt32 display ID, Bool primary flag,
`DisplayType`, CGRect bounds, CGSize native size, Int point scale, two String
rotations, and two `DeviceOrientation` getters. Foreign type descriptors
`0x4e3260` and `0x4e3280` name CGRect and CGSize; the UInt32 typeref binds its
Swift descriptor. String getters retain and return two words; enum/optional
getters write indirect results. Some getter bodies are folded together, so use
canonical symbol-to-address mappings and reflection, not an incidental label.
Both enums have no payload cases. Reflected order matches the exported enum-case
constants: DeviceOrientation's seven cases at `0x485384..0x48539c`, and
DisplayType's six at `0x49ca0c..0x49ca20`. Use resilient enum cases, not those
numeric tags as a new source contract.

For updates, recheck field descriptors, value witnesses, getter return conventions
and enum-case constants as well as the associated aliases and protocol effects.
Only canonical Swift descriptor symbols are evidence: synthetic `$ld$hide$...`
linker aliases with similar suffixes are not type descriptors. Static ABI evidence
does not establish initial stream delivery, remote update ordering, teardown
semantics or protected-host behavior.

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
