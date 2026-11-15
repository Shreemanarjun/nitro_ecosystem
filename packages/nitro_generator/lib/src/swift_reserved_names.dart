// Names the Swift compiler rejects where the generated bridge declares them.
// The bridge writes a name from the spec as it is, with no backticks, so a
// method called `where` or a variant case that becomes `default` did not
// compile on iOS or macOS, with nothing reported before the compiler did.
//
// Taken from the Swift compiler in Xcode 27.2. Every Swift keyword, and the
// names the bridge uses itself, was put in each position of a generated bridge
// and typechecked; the ones swiftc rejected were kept, per position. A word
// that only some positions reject (`await` as a field, `impl` as a parameter)
// is listed for those positions alone, so a spec that compiles today still does.

/// Where a name from the spec lands in the Swift bridge.
enum SwiftNameUse { method, parameter, property, field, enumValue, variantCase, variantField }

/// Rejected in every position. The ones Dart reserves too (`default`, `case`,
/// `in`, …) can only arrive as a `@NitroVariant` case, which takes its Swift
/// name from the class name: `ModeDefault` becomes `default`.
const swiftReservedWords = <String>{
  'Any', 'as', 'associatedtype', 'break', 'case', 'catch', 'class', 'continue', 'default', 'defer', 'deinit', 'do', 'else', 'enum', 'extension',
  'fallthrough', 'false', 'fileprivate', 'for', 'func', 'guard', 'if', 'import', 'in', 'init', 'inout', 'internal', 'is', 'let', 'nil', 'operator',
  'precedencegroup', 'private', 'protocol', 'public', 'repeat', 'rethrows', 'return', 'static', 'struct', 'subscript', 'super', 'switch', 'throw',
  'throws', 'true', 'try', 'typealias', 'var', 'where', 'while',
};

/// Rejected in some positions only. `impl` is not a Swift word: the call stub
/// of a Swift-implemented module has a local of that name.
const _alsoRejected = <SwiftNameUse, Set<String>>{
  SwiftNameUse.method: {'self', 'Self'},
  SwiftNameUse.parameter: {'await', 'impl'},
  SwiftNameUse.property: {'self', 'Self', 'Protocol', 'Type'},
  SwiftNameUse.field: {'self', 'Self', 'Protocol', 'Type', 'await'},
  SwiftNameUse.enumValue: {'self', 'Self', 'Protocol', 'Type'},
  SwiftNameUse.variantCase: {'self', 'Self'},
  SwiftNameUse.variantField: {'Self', 'await'},
};

/// True when the Swift bridge cannot declare [name] in position [use].
///
/// [hasCallStubs] is false for a module that is C++ on every Apple platform it
/// targets: its bridge has no `@_cdecl` stubs, so a parameter is only ever an
/// argument label, and Swift accepts every word but `inout` as one.
bool swiftRejectsName(String name, SwiftNameUse use, {bool hasCallStubs = true}) {
  if (use == SwiftNameUse.parameter && !hasCallStubs) return name == 'inout';
  return swiftReservedWords.contains(name) || _alsoRejected[use]!.contains(name);
}
