/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// In-process Swift runtime metadata probe for idb-repl.
//
// It walks a target image's Swift metadata and symbol table to reconstruct a
// best-effort `.swiftinterface` for each module the image contains, and writes
// one `<Module>.swiftinterface` file per module. It lives only in the `libShimulator`
// shim.
//
// Sources used:
//   - `__TEXT,__swift5_types` type context descriptors  -> type kind, name,
//     module, and stored properties (names + resolved types).
//   - the image's Mach-O symbol table (`LC_SYMTAB`) demangled via
//     `swift_demangle` -> methods, static methods, initializers, computed
//     properties, and free functions. Methods on structs, `static` methods and
//     free functions are NOT in any runtime metadata table, so the symbol table
//     is the source for the callable surface.
//
// Not recovered: generic declarations, enum cases / payload layout, nested types,
// argument internal names, faithful ABI layout.
//
// Parsing is defensive: any malformed/unsupported descriptor or symbol is
// skipped rather than crashing the host process.

// patternlint-disable cdecl-unsupported

import Foundation
import MachO

// MARK: - Context descriptor kinds (low 5 bits of the descriptor Flags word)

private let kindModule: UInt32 = 0
private let kindClass: UInt32 = 16
private let kindStruct: UInt32 = 17
private let kindEnum: UInt32 = 18

private let flagIsGeneric: UInt32 = 0x80 // bit 7 of the Flags word

// MARK: - Relative pointers
// Swift relative pointers are 32-bit signed offsets from the field's own address.
// "Indirectable" pointers use the low bit to mean "the target is a pointer to the
// value" rather than the value itself.

@inline(__always)
private func relativeDirect(_ field: UnsafeRawPointer) -> UnsafeRawPointer? {
  let offset = unsafe field.loadUnaligned(as: Int32.self)
  if offset == 0 { return nil }
  return unsafe field.advanced(by: Int(offset))
}

@inline(__always)
private func relativeIndirectable(_ field: UnsafeRawPointer) -> UnsafeRawPointer? {
  let raw = unsafe field.loadUnaligned(as: Int32.self)
  if raw == 0 { return nil }
  let target = unsafe field.advanced(by: Int(raw & ~1))
  if (raw & 1) != 0 {
    let p = unsafe target.loadUnaligned(as: UInt.self)
    return unsafe p == 0 ? nil : UnsafeRawPointer(bitPattern: p)
  }
  return unsafe target
}

@inline(__always)
private func cString(at ptr: UnsafeRawPointer?) -> String? {
  guard let ptr = unsafe ptr else { return nil }
  return unsafe String(cString: ptr.assumingMemoryBound(to: CChar.self))
}

// MARK: - Swift runtime entry points (resolved dynamically)
//
// These symbol names are reserved by the Swift runtime and cannot be bound with
// `@_silgen_name`, so resolve them with `dlsym` and call through C function
// pointers instead. RTLD_DEFAULT is ((void *)-2) on Darwin: search every loaded
// image for the libswiftCore entry point.

private var rtldDefault: UnsafeMutableRawPointer? {
  unsafe UnsafeMutableRawPointer(bitPattern: -2)
}

// Returns the type metadata pointer (Swift runtime `const Metadata *`); callers
// bitcast it to `Any.Type`. A metatype isn't `@convention(c)`-representable, so
// the C signature uses a raw pointer.
private typealias GetTypeByMangledNameInContext =
  @convention(c) (
    _ name: UnsafePointer<UInt8>,
    _ length: UInt,
    _ context: UnsafeRawPointer?,
    _ genericArgs: UnsafeRawPointer?
  ) -> UnsafeRawPointer?

private let getTypeByMangledNameInContext: GetTypeByMangledNameInContext? = {
  guard let symbol = unsafe dlsym(rtldDefault, "swift_getTypeByMangledNameInContext") else {
    return nil
  }
  return unsafe unsafeBitCast(symbol, to: GetTypeByMangledNameInContext.self)
}()

private typealias SwiftDemangle =
  @convention(c) (
    _ mangledName: UnsafePointer<CChar>?,
    _ mangledNameLength: Int,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<Int>?,
    _ flags: UInt32
  ) -> UnsafeMutablePointer<CChar>?

private let swiftDemangle: SwiftDemangle? = {
  guard let symbol = unsafe dlsym(rtldDefault, "swift_demangle") else {
    return nil
  }
  return unsafe unsafeBitCast(symbol, to: SwiftDemangle.self)
}()

private func demangle(_ mangled: String) -> String? {
  guard let demangler = unsafe swiftDemangle else { return nil }
  return mangled.withCString { cstr -> String? in
    guard let out = unsafe demangler(cstr, strlen(cstr), nil, nil, 0) else { return nil }
    defer { unsafe free(out) }
    return unsafe String(cString: out)
  }
}

/// Length of a mangled type-name string, accounting for embedded symbolic
/// references (whose 4- or 8-byte operands may themselves contain null bytes,
/// so a plain `strlen` is wrong).
private func mangledNameLength(_ start: UnsafeRawPointer) -> Int {
  var p = unsafe start
  while true {
    let b = unsafe p.loadUnaligned(as: UInt8.self)
    if b == 0 { break }
    if b >= 0x01, b <= 0x17 {
      unsafe p = unsafe p.advanced(by: 5) // 1 control byte + 4-byte relative reference
    } else if b >= 0x18, b <= 0x1F {
      unsafe p = unsafe p.advanced(by: 9) // 1 control byte + 8-byte absolute reference
    } else {
      unsafe p = unsafe p.advanced(by: 1)
    }
  }
  return unsafe start.distance(to: p)
}

/// Best-effort: resolve a field's mangled type reference to a qualified Swift
/// type spelling (e.g. "Swift.Int"). Returns nil if the type can't be resolved
/// in-process (e.g. unbound generic), so callers can fall back to a placeholder.
private func resolveTypeName(_ mangled: UnsafeRawPointer?, context: UnsafeRawPointer) -> String? {
  guard let mangled = unsafe mangled, let resolve = unsafe getTypeByMangledNameInContext else { return nil }
  let len = unsafe mangledNameLength(mangled)
  guard len > 0 else { return nil }
  let bytes = unsafe mangled.assumingMemoryBound(to: UInt8.self)
  guard let metadata = unsafe resolve(bytes, UInt(len), context, nil) else {
    return nil
  }
  let type = unsafe unsafeBitCast(metadata, to: Any.Type.self)
  return String(reflecting: type)
}

// MARK: - Type descriptor walking

private struct FieldInfo {
  let name: String
  let typeName: String
}

private struct TypeInfo {
  let module: String
  let name: String
  let keyword: String // "class" | "struct" | "enum"
}

/// Resolve a `__swift5_types` record (a relative, possibly-indirect pointer) to
/// the type context descriptor it names.
private func resolveTypeRecord(_ entry: UnsafeRawPointer) -> UnsafeRawPointer? {
  let raw = unsafe entry.loadUnaligned(as: Int32.self)
  if raw == 0 { return nil }
  let target = unsafe entry.advanced(by: Int(raw & ~1))
  if (raw & 1) != 0 {
    let p = unsafe target.loadUnaligned(as: UInt.self)
    return unsafe p == 0 ? nil : UnsafeRawPointer(bitPattern: p)
  }
  return unsafe target
}

/// Walk the parent chain to the enclosing module descriptor and read its name.
private func moduleName(of descriptor: UnsafeRawPointer) -> String? {
  var current: UnsafeRawPointer? = unsafe relativeIndirectable(descriptor.advanced(by: 4)) // Parent
  var depth = 0
  while let c = unsafe current, depth < 16 {
    let kind = unsafe c.loadUnaligned(as: UInt32.self) & 0x1F
    if kind == kindModule {
      return unsafe cString(at: relativeDirect(c.advanced(by: 8))) // module descriptor: Name at +8
    }
    unsafe current = unsafe relativeIndirectable(c.advanced(by: 4))
    depth += 1
  }
  return nil
}

/// Whether the descriptor's immediate parent is a module (a top-level type); nested
/// types are not recovered.
private func isTopLevel(_ descriptor: UnsafeRawPointer) -> Bool {
  guard let parent = unsafe relativeIndirectable(descriptor.advanced(by: 4)) else { return false }
  return unsafe (parent.loadUnaligned(as: UInt32.self) & 0x1F) == kindModule
}

/// The kind/name/module of a top-level, non-generic nominal type, or nil to skip.
private func typeInfo(of descriptor: UnsafeRawPointer) -> TypeInfo? {
  let flags = unsafe descriptor.loadUnaligned(as: UInt32.self)
  guard (flags & flagIsGeneric) == 0 else { return nil } // generics are not recovered
  guard unsafe isTopLevel(descriptor) else { return nil } // nested types are not recovered

  let keyword: String
  switch flags & 0x1F {
  case kindClass: keyword = "class"
  case kindStruct: keyword = "struct"
  case kindEnum: keyword = "enum"
  default: return nil
  }
  guard let name = unsafe cString(at: relativeDirect(descriptor.advanced(by: 8))) else { return nil } // Name at +8
  let module = unsafe moduleName(of: descriptor) ?? "Unknown"
  return TypeInfo(module: module, name: name, keyword: keyword)
}

/// Stored properties from the type's field descriptor (`Fields` at +16).
private func storedFields(of descriptor: UnsafeRawPointer) -> [FieldInfo] {
  guard let fd = unsafe relativeDirect(descriptor.advanced(by: 16)) else { return [] }
  let recordSize = unsafe Int(fd.advanced(by: 10).loadUnaligned(as: UInt16.self))
  let numFields = unsafe Int(fd.advanced(by: 12).loadUnaligned(as: UInt32.self))
  guard recordSize >= 12, numFields > 0, numFields < 4096 else { return [] }
  let records = unsafe fd.advanced(by: 16)
  var fields: [FieldInfo] = []
  for i in 0..<numFields {
    let rec = unsafe records.advanced(by: i * recordSize)
    let name = unsafe cString(at: relativeDirect(rec.advanced(by: 8))) ?? "field\(i)" // FieldName at +8
    let typeName =
      unsafe resolveTypeName(relativeDirect(rec.advanced(by: 4)), context: descriptor) // MangledTypeName at +4
      ?? "Any /* TODO: unresolved type */"
    fields.append(FieldInfo(name: name, typeName: typeName))
  }
  return fields
}

// MARK: - Symbol table walking & demangle parsing

/// A method/initializer/free function recovered from a demangled symbol, or a
/// single accessor of a computed property.
private enum ParsedSymbol {
  /// `typeName == nil` means a module-level free function. `decl` is the bare
  /// declaration without indentation, e.g. `public static func f(_: Swift.Int)`.
  case callable(module: String, typeName: String?, decl: String)
  case accessor(module: String, typeName: String, property: String, type: String, isSetter: Bool, isStatic: Bool)
}

/// Per-image recovered members, keyed by module then by type name.
private struct ImageMembers {
  /// module -> typeName -> ordered, de-duplicated declaration lines (bare).
  var typeMethods: [String: [String: [String]]] = [:]
  /// module -> ordered free-function declarations (bare).
  var freeFunctions: [String: [String]] = [:]
  /// module -> typeName -> property -> (type, hasGetter, hasSetter, isStatic).
  var accessors: [String: [String: [String: AccessorInfo]]] = [:]

  struct AccessorInfo {
    var type: String
    var hasGetter: Bool = false
    var hasSetter: Bool = false
    var isStatic: Bool = false
  }
}

private let accessorKinds: [(suffix: String, isSetter: Bool)] = [
  (".getter", false), (".setter", true), (".modify", true), (".read", false),
]

/// Demangled fragments that mark a symbol we cannot faithfully reconstruct, so
/// the whole symbol is skipped. Unlike a blocklist of generic words, each marker
/// is specific enough that it never occurs inside a legitimate identifier or type
/// spelling:
///   - " with unmangled suffix": compiler-internal forms the demangler couldn't
///     fully parse, e.g. the ".resume.N" continuations of `_read`/`_modify`
///     coroutine accessors (these would otherwise corrupt the property's type).
///   - ".(": a private/anonymous declaration context, e.g. "Type.(_x in _ABC)".
///   - "Builtin." / "__C.": types in pseudo-modules that no interface can import.
private let nonReconstructibleMarkers = [
  " with unmangled suffix", ".(", "Builtin.", "__C.",
]

/// Reconstruct a declaration (or accessor) from a demangled symbol string.
private func parseSymbol(_ demangledInput: String) -> ParsedSymbol? {
  for marker in nonReconstructibleMarkers where demangledInput.contains(marker) {
    return nil
  }

  var s = demangledInput
  var isStatic = false
  if s.hasPrefix("static ") {
    isStatic = true
    s = String(s.dropFirst("static ".count))
  }

  // Detect computed-property accessors first. Their property type may itself
  // contain parens (function types like "() -> T", tuples like "(Int, String)"),
  // so we cannot classify on the absence of "(".
  if let accessor = parseAccessor(s, isStatic: isStatic) {
    return accessor
  }

  guard let parenIndex = s.firstIndex(of: "(") else { return nil }

  let qualified = String(s[s.startIndex..<parenIndex]).trimmingCharacters(in: .whitespaces)
  guard let closeIndex = matchingParen(s, openAfter: parenIndex) else { return nil }
  let paramInner = String(s[s.index(after: parenIndex)..<closeIndex])
  let tail = String(s[s.index(after: closeIndex)...])

  let components = qualified.split(separator: ".").map(String.init)
  guard components.count >= 2 else { return nil }
  // A real declaration's qualified name is all Swift identifiers. Runtime helper
  // symbols demangle to descriptive phrases ("type metadata for X", "dispatch
  // thunk of X", "merged X", ...) whose components contain spaces/<>, so this
  // rejects them structurally without dropping legitimate identifiers like
  // `mergedItems` or a type named `WitnessTable`. Note an `@objc` method is still
  // recovered via its native Swift symbol; only its separate ObjC thunk
  // ("@objc Module.Type.method(...)") is dropped here, avoiding a duplicate.
  guard components.allSatisfy(isIdentifier) else { return nil }
  let module = components[0]
  let member = components[components.count - 1]
  let typePath = Array(components[1..<(components.count - 1)])
  if typePath.count > 1 { return nil } // members of nested types are not recovered
  if member == "deinit" || member.hasPrefix("__") { return nil }

  let params = reformatParameters(paramInner)
  let isAsync = tail.contains(" async")
  let isThrows = tail.contains("throws")
  let returnType = parseReturnType(tail)

  var decl = ""
  if member == "init" {
    decl = "public init(\(params))"
    if isAsync { decl += " async" }
    if isThrows { decl += " throws" }
  } else {
    decl = "public "
    if isStatic { decl += "static " }
    decl += "func \(member)(\(params))"
    if isAsync { decl += " async" }
    if isThrows { decl += " throws" }
    if let returnType, returnType != "()", returnType != "Swift.Void" {
      decl += " -> \(returnType)"
    }
  }

  return .callable(module: module, typeName: typePath.first, decl: decl)
}

/// Parse a computed-property accessor symbol, e.g. "Module.Type.prop.getter : T".
private func parseAccessor(_ s: String, isStatic: Bool) -> ParsedSymbol? {
  // Split on the accessor separator — the first " : ". (Tuple labels demangle as
  // "label:" with no leading space, so an inner labeled tuple in the property
  // type won't match.) The accessor kind is then the suffix the left side ends
  // with, which keeps the match anchored rather than searching the whole string.
  guard let colon = s.range(of: " : ") else { return nil }
  let lhs = String(s[s.startIndex..<colon.lowerBound])
  let type = String(s[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
  guard let kind = accessorKinds.first(where: { lhs.hasSuffix($0.suffix) }) else { return nil }

  let nameQualified = String(lhs.dropLast(kind.suffix.count))
  let components = nameQualified.split(separator: ".").map(String.init)
  guard components.count >= 3 else { return nil } // module + type + property
  // Same structural check as parseSymbol: every qualified-name component is a
  // Swift identifier in a real declaration, so descriptive runtime-helper
  // phrases are rejected without dropping legitimate identifiers.
  guard components.allSatisfy(isIdentifier) else { return nil }
  let module = components[0]
  let property = components[components.count - 1]
  let typePath = Array(components[1..<(components.count - 1)])
  guard typePath.count == 1 else { return nil } // skip nested types

  return .accessor(
    module: module,
    typeName: typePath[0],
    property: property,
    type: type,
    isSetter: kind.isSetter,
    isStatic: isStatic)
}

private func parseReturnType(_ tail: String) -> String? {
  guard let arrow = tail.range(of: "-> ") else { return nil }
  return String(tail[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
}

/// Reformat a demangled parameter list into valid interface syntax: demangle
/// renders an unlabeled parameter as just its type, which we turn into `_: Type`.
private func reformatParameters(_ inner: String) -> String {
  let trimmed = inner.trimmingCharacters(in: .whitespaces)
  if trimmed.isEmpty { return "" }
  return splitTopLevel(trimmed, separator: ",")
    .map { part -> String in
      let p = part.trimmingCharacters(in: .whitespaces)
      return hasTopLevelColon(p) ? p : "_: \(p)"
    }
    .joined(separator: ", ")
}

private func isIdentifier(_ s: String) -> Bool {
  guard let first = s.first, first == "_" || first.isLetter else { return false }
  return s.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
}

/// Adjusts `depth` for one character of parens/brackets/angles, ignoring the `>` in `->`.
private func adjustDepth(_ ch: Character, _ prev: Character, _ depth: inout Int) {
  switch ch {
  case "(", "[", "<":
    depth += 1
  case ")", "]":
    depth -= 1
  case ">":
    if prev != "-" { depth -= 1 } // ignore the '>' in '->'
  default:
    break
  }
}

private func splitTopLevel(_ s: String, separator: Character) -> [String] {
  var result: [String] = []
  var current = ""
  var depth = 0
  var prev: Character = " "
  for ch in s {
    if ch == separator, depth == 0 {
      result.append(current)
      current = ""
    } else {
      adjustDepth(ch, prev, &depth)
      current.append(ch)
    }
    prev = ch
  }
  if !current.isEmpty { result.append(current) }
  return result
}

private func hasTopLevelColon(_ s: String) -> Bool {
  var depth = 0
  var prev: Character = " "
  for ch in s {
    if ch == ":", depth == 0 { return true }
    adjustDepth(ch, prev, &depth)
    prev = ch
  }
  return false
}

/// Index of the close paren matching the `(` at `openAfter`.
private func matchingParen(_ s: String, openAfter: String.Index) -> String.Index? {
  var depth = 0
  var i = openAfter
  while i < s.endIndex {
    let ch = s[i]
    if ch == "(" {
      depth += 1
    } else if ch == ")" {
      depth -= 1
      if depth == 0 { return i }
    }
    i = s.index(after: i)
  }
  return nil
}

private func readSegmentName(_ command: UnsafeRawPointer) -> String {
  // segname is a 16-byte field at offset 8 in segment_command_64.
  let p = unsafe command.advanced(by: 8)
  var bytes = [UInt8](repeating: 0, count: 16)
  for i in 0..<16 { bytes[i] = unsafe p.advanced(by: i).loadUnaligned(as: UInt8.self) }
  return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
}

/// Walk an image's symbol table, demangle each Swift symbol, and collect the
/// methods, initializers, computed properties, and free functions it defines.
private func collectMembers(in header: UnsafeRawPointer, slide: Int) -> ImageMembers {
  var members = ImageMembers()
  let mh = unsafe header.assumingMemoryBound(to: mach_header_64.self)
  guard unsafe mh.pointee.magic == MH_MAGIC_64 else { return members }

  var command = unsafe header.advanced(by: MemoryLayout<mach_header_64>.size)
  var linkeditVMAddr: UInt64 = 0
  var linkeditFileOff: UInt64 = 0
  var haveLinkedit = false
  var symOff: UInt32 = 0
  var numSyms: UInt32 = 0
  var strOff: UInt32 = 0
  var haveSymtab = false

  for _ in unsafe 0..<Int(mh.pointee.ncmds) {
    let lc = unsafe command.loadUnaligned(as: load_command.self)
    if lc.cmd == UInt32(LC_SEGMENT_64) {
      let seg = unsafe command.loadUnaligned(as: segment_command_64.self)
      if unsafe readSegmentName(command) == "__LINKEDIT" {
        linkeditVMAddr = seg.vmaddr
        linkeditFileOff = seg.fileoff
        haveLinkedit = true
      }
    } else if lc.cmd == UInt32(LC_SYMTAB) {
      let st = unsafe command.loadUnaligned(as: symtab_command.self)
      symOff = st.symoff
      numSyms = st.nsyms
      strOff = st.stroff
      haveSymtab = true
    }
    unsafe command = unsafe command.advanced(by: Int(lc.cmdsize))
  }
  guard haveLinkedit, haveSymtab, numSyms > 0 else { return members }

  let fileBase = slide + Int(linkeditVMAddr) - Int(linkeditFileOff)
  guard let symBase = unsafe UnsafeRawPointer(bitPattern: fileBase + Int(symOff)),
    let strBase = unsafe UnsafeRawPointer(bitPattern: fileBase + Int(strOff))
  else { return members }

  for i in 0..<Int(numSyms) {
    let n = unsafe symBase.advanced(by: i * MemoryLayout<nlist_64>.size).loadUnaligned(as: nlist_64.self)
    guard (n.n_type & UInt8(N_STAB)) == 0 else { continue } // skip debug entries
    guard (n.n_type & UInt8(N_TYPE)) == UInt8(N_SECT) else { continue } // defined in a section
    let strx = unsafe Int(n.n_un.n_strx)
    guard strx != 0 else { continue }
    let raw = unsafe String(cString: strBase.advanced(by: strx).assumingMemoryBound(to: CChar.self))
    // Symbol table names carry a leading '_'; Swift mangling then starts "$s"/"$S".
    guard raw.hasPrefix("_$s") || raw.hasPrefix("_$S") else { continue }
    guard let demangled = demangle(String(raw.dropFirst())) else { continue }
    guard let parsed = parseSymbol(demangled) else { continue }
    record(parsed, into: &members)
  }

  return members
}

private func record(_ parsed: ParsedSymbol, into members: inout ImageMembers) {
  switch parsed {
  case let .callable(module, typeName, decl):
    guard let typeName else {
      var list = members.freeFunctions[module] ?? []
      if !list.contains(decl) { list.append(decl) }
      members.freeFunctions[module] = list
      return
    }
    var byType = members.typeMethods[module] ?? [:]
    var list = byType[typeName] ?? []
    if !list.contains(decl) { list.append(decl) }
    byType[typeName] = list
    members.typeMethods[module] = byType

  case let .accessor(module, typeName, property, type, isSetter, isStatic):
    var byType = members.accessors[module] ?? [:]
    var byProp = byType[typeName] ?? [:]
    var info = byProp[property] ?? ImageMembers.AccessorInfo(type: type)
    info.type = type
    info.isStatic = info.isStatic || isStatic
    if isSetter { info.hasSetter = true } else { info.hasGetter = true }
    byProp[property] = info
    byType[typeName] = byProp
    members.accessors[module] = byType
  }
}

// MARK: - Image enumeration

private func matchingImages(filter: String) -> [(header: UnsafeRawPointer, slide: Int)] {
  var images: [(UnsafeRawPointer, Int)] = unsafe []
  let count = _dyld_image_count()
  var i: UInt32 = 0
  while i < count {
    defer { i += 1 }
    guard let nameC = unsafe _dyld_get_image_name(i) else { continue }
    guard unsafe String(cString: nameC).contains(filter) else { continue }
    if let header = unsafe _dyld_get_image_header(i) {
      unsafe images.append((UnsafeRawPointer(header), _dyld_get_image_vmaddr_slide(i)))
    }
  }
  return unsafe images
}

private func typeDescriptors(in header: UnsafeRawPointer) -> [UnsafeRawPointer] {
  var size: UInt = 0
  let mh = unsafe header.assumingMemoryBound(to: mach_header_64.self)
  guard let section = unsafe getsectiondata(mh, "__TEXT", "__swift5_types", &size) else { return unsafe [] }
  let base = UnsafeRawPointer(section)
  let count = Int(size) / 4
  var descriptors: [UnsafeRawPointer] = unsafe []
  for i in 0..<count {
    if let desc = unsafe resolveTypeRecord(base.advanced(by: i * 4)) {
      unsafe descriptors.append(desc)
    }
  }
  return unsafe descriptors
}

// MARK: - Interface rendering

/// Whether a declaration can be expressed in the interface. The implicit Clang
/// module `__C` and the `Builtin` pseudo-module cannot be imported by name, so
/// drop declarations whose types reference them. (Symbol-derived members are
/// already dropped at parse time; this also covers stored fields, which come from
/// reflection metadata and bypass that path.)
private func isExpressible(_ declaration: String) -> Bool {
  return !declaration.contains("__C.") && !declaration.contains("Builtin.")
}

/// The foreign modules a body references (the leading component of each qualified
/// type name), excluding the module's own name and modules that are implicit or
/// non-importable. Emitting `import`s for these makes the interface
/// self-contained so the local `swiftc` can compile it.
private func referencedModules(in body: String, ownModule: String) -> [String] {
  guard let regex = try? NSRegularExpression(pattern: #"(?<![\w.])([A-Za-z_]\w*)\."#) else { return [] }
  let ns = body as NSString
  var modules = Set<String>()
  for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
    modules.insert(ns.substring(with: match.range(at: 1)))
  }
  modules.subtract([ownModule, "Swift", "__C", "Builtin"])
  return modules.sorted()
}

private func renderType(
  _ info: TypeInfo,
  fields: [FieldInfo],
  methods: [String],
  accessors: [String: ImageMembers.AccessorInfo]
) -> String {
  var lines = ["public \(info.keyword) \(info.name) {"]

  if info.keyword == "enum" {
    lines.append("  // TODO: enum cases / payload layout not yet recovered")
  } else {
    for field in fields where isExpressible(field.typeName) {
      lines.append("  public var \(field.name): \(field.typeName)")
    }
  }

  // Computed properties (from accessor symbols), skipping stored fields.
  let storedNames = Set(fields.map(\.name))
  for property in accessors.keys.sorted() where !storedNames.contains(property) {
    guard let info = accessors[property], info.hasGetter, isExpressible(info.type) else { continue }
    let staticPrefix = info.isStatic ? "static " : ""
    let accessorClause = info.hasSetter ? "{ get set }" : "{ get }"
    lines.append("  public \(staticPrefix)var \(property): \(info.type) \(accessorClause)")
  }

  // Sort for deterministic output: methods arrive in symbol-table order, which
  // can vary between builds. Matches the sorted computed-property section above.
  for method in methods.sorted() where isExpressible(method) {
    lines.append("  \(method)")
  }

  lines.append("}")
  return lines.joined(separator: "\n")
}

private func renderInterface(module: String, declarations: [String]) -> String {
  let body = declarations.joined(separator: "\n\n")
  let importLines = referencedModules(in: body, ownModule: module).map { "import \($0)" }
  var out = "// swift-interface-format-version: 1.0\n"
  out += "// Generated by idb-repl RuntimeProbe. Best-effort reconstruction; not ABI-complete.\n"
  out += "// swift-module-flags: -module-name \(module)\n\n"
  if !importLines.isEmpty {
    out += importLines.joined(separator: "\n") + "\n\n"
  }
  out += body
  out += "\n"
  return out
}

// MARK: - Probe

final class RuntimeProbe {
  /// Enumerate the Swift types in the image(s) whose path contains
  /// `imageNameFilter`, write one `<Module>.swiftinterface` per module into
  /// `outputDir`, and return the paths of every file written (empty on failure).
  func generateInterfaces(outputDir: String, imageNameFilter: String) -> [String] {
    guard !imageNameFilter.isEmpty else {
      NSLog("[idb-repl][probe] no image filter provided; refusing to scan all images")
      return []
    }
    let images = unsafe matchingImages(filter: imageNameFilter)
    guard unsafe !images.isEmpty else {
      NSLog("[idb-repl][probe] no loaded image matched '%@'", imageNameFilter)
      return []
    }

    var declarationsByModule: [String: [String]] = [:]
    // swift-format would join `for unsafe` into one word.
    // swift-format-ignore
    for unsafe (header, slide) in unsafe images {
      let members = unsafe collectMembers(in: header, slide: slide)

      // swift-format would join `for unsafe` into one word.
      // swift-format-ignore
      for unsafe descriptor in unsafe typeDescriptors(in: header) {
        guard let info = unsafe typeInfo(of: descriptor) else { continue }
        let fields = unsafe info.keyword == "enum" ? [] : storedFields(of: descriptor)
        let methods = members.typeMethods[info.module]?[info.name] ?? []
        let accessors = members.accessors[info.module]?[info.name] ?? [:]
        let declaration = renderType(info, fields: fields, methods: methods, accessors: accessors)
        declarationsByModule[info.module, default: []].append(declaration)
      }

      for (module, functions) in members.freeFunctions {
        // Sorted for the same determinism reason as methods above.
        declarationsByModule[module, default: []].append(contentsOf: functions.sorted().filter(isExpressible))
      }
    }
    guard !declarationsByModule.isEmpty else {
      NSLog("[idb-repl][probe] matched image(s) but recovered no top-level Swift types")
      return []
    }

    try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    var writtenPaths: [String] = []
    for (module, declarations) in declarationsByModule {
      let text = renderInterface(module: module, declarations: declarations)
      let path = (outputDir as NSString).appendingPathComponent("\(module).swiftinterface")
      do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        NSLog("[idb-repl][probe] wrote %@ (%d decls)", path, declarations.count)
        writtenPaths.append(path)
      } catch {
        NSLog("[idb-repl][probe] failed to write %@: %@", path, "\(error)")
      }
    }
    return writtenPaths
  }
}

// MARK: - C entry point (called from the ObjC shim; see TestRepl.m)

/// Generates `.swiftinterface` file(s) for the matching image(s) and returns the
/// written paths joined by newlines in a malloc'd string (the caller must
/// `free` it), or NULL when nothing was generated.
@_cdecl("FBReplGenerateSwiftInterface")
public func FBReplGenerateSwiftInterface(
  _ outDirC: UnsafePointer<CChar>?,
  _ imageFilterC: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>? {
  let outDir = unsafe outDirC.map { unsafe String(cString: $0) } ?? NSTemporaryDirectory()
  let filter = unsafe imageFilterC.map { unsafe String(cString: $0) } ?? ""
  let paths = RuntimeProbe().generateInterfaces(outputDir: outDir, imageNameFilter: filter)
  guard !paths.isEmpty else { return nil }
  guard let duplicated = unsafe strdup(paths.joined(separator: "\n")) else {
    return nil
  }
  return unsafe UnsafePointer(duplicated)
}
