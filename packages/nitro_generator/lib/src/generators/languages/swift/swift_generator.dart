import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../enum_generator.dart';
import '../../generator_metadata.dart';
import '../../record_generator.dart';
import '../../struct_generator.dart';
import 'package:nitro_annotations/nitro_annotations.dart' show CppImpl;

class SwiftGenerator {
  static String generate(BridgeSpec spec) {
    if (spec.isTypeOnly) return _generateTypeOnly(spec);
    if (spec.iosImpl == null) {
      return '${generatedFileHeader('//', sourceUri: spec.sourceUri)}\n'
          '// iOS not targeted — no Swift bridge generated.\n';
    }

    // For NativeImpl.cpp (CppImpl) modules, the C++ .mm shim calls the
    // native C functions directly (e.g. benchmark_cpp_add). It does NOT
    // use @_cdecl Swift stubs. Emitting @_cdecl stubs here would cause
    // duplicate-symbol linker errors when both a Swift and a C++ module
    // are compiled into the same target — they share the same symbol names.
    //
    // Shared types (structs, NitroRecordWriter, NitroRecordReader) are
    // declared by the Swift module's .bridge.g.swift, which is compiled
    // in the same module. Do NOT redeclare them here.
    final isCppModule = spec.iosImpl is CppImpl;
    if (isCppModule) {
      return _generateCppModuleBridge(spec);
    }

    final writer = CodeWriter();
    writer.raw(generatedFileHeader('//', sourceUri: spec.sourceUri));
    writer.line('import Foundation');
    writer.line('import Combine');
    // @nitroNativeAsync stubs use Dart_CObject / Dart_PostCObject_DL, which are
    // C types from dart_api.h — exposed by the sibling SPM C++ target.
    final hasNativeAsync = spec.functions.any((f) => f.isNativeAsync);
    if (hasNativeAsync) {
      writer.line('import ${spec.dartClassName}Cpp');
    }
    writer.blankLine();

    final swiftEnums = EnumGenerator.generateSwift(spec);
    if (swiftEnums.isNotEmpty) writer.raw(swiftEnums);

    final swiftStructs = StructGenerator.generateSwift(spec);
    if (swiftStructs.isNotEmpty) writer.raw(swiftStructs);

    final swiftRecords = RecordGenerator.generateSwift(spec);
    if (swiftRecords.isNotEmpty) writer.raw(swiftRecords);

    if (spec.functions.any((f) => f.returnType.isTypedData)) {
      writer.line('private func _nitroCopyTypedDataReturn(_ bytes: UnsafeRawBufferPointer) -> UnsafeMutablePointer<UInt8>? {');
      writer.line('    let headerSize = MemoryLayout<Int64>.size');
      writer.line('    let byteLength = bytes.count');
      writer.line('    guard let raw = malloc(byteLength + headerSize) else { return nil }');
      writer.line('    raw.storeBytes(of: Int64(byteLength), as: Int64.self)');
      writer.line('    if let base = bytes.baseAddress, byteLength > 0 {');
      writer.line('        memcpy(raw.advanced(by: headerSize), base, byteLength)');
      writer.line('    }');
      writer.line('    return raw.bindMemory(to: UInt8.self, capacity: byteLength + headerSize)');
      writer.line('}');
      writer.blankLine();
      writer.line('private func _nitroCopyTypedDataArrayReturn<T>(_ values: [T]) -> UnsafeMutablePointer<UInt8>? {');
      writer.line('    return values.withUnsafeBufferPointer { buffer in');
      writer.line('        _nitroCopyTypedDataReturn(UnsafeRawBufferPointer(buffer))');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
      writer.line('private func _nitroMakeZeroCopyTypedDataReturn(_ bytes: UnsafeRawBufferPointer) -> UnsafeMutablePointer<UInt8>? {');
      writer.line('    let headerSize = MemoryLayout<Int64>.size * 3');
      writer.line('    let byteLength = bytes.count');
      writer.line('    guard let raw = malloc(byteLength + headerSize) else { return nil }');
      writer.line('    raw.storeBytes(of: Int64(byteLength), as: Int64.self)');
      writer.line('    let payload = raw.advanced(by: headerSize)');
      writer.line('    raw.advanced(by: MemoryLayout<Int64>.size).storeBytes(of: Int64(Int(bitPattern: payload)), as: Int64.self)');
      writer.line('    raw.advanced(by: MemoryLayout<Int64>.size * 2).storeBytes(of: Int64(0), as: Int64.self)');
      writer.line('    if let base = bytes.baseAddress, byteLength > 0 {');
      writer.line('        memcpy(payload, base, byteLength)');
      writer.line('    }');
      writer.line('    return raw.bindMemory(to: UInt8.self, capacity: byteLength + headerSize)');
      writer.line('}');
      writer.blankLine();
      writer.line('private func _nitroMakeZeroCopyTypedDataArrayReturn<T>(_ values: [T]) -> UnsafeMutablePointer<UInt8>? {');
      writer.line('    return values.withUnsafeBufferPointer { buffer in');
      writer.line('        _nitroMakeZeroCopyTypedDataReturn(UnsafeRawBufferPointer(buffer))');
      writer.line('    }');
      writer.line('}');
      writer.blankLine();
    }

    // ── Protocol ──────────────────────────────────────────────────────────
    writer.line('/**');
    writer.line(' * Protocol for the ${spec.dartClassName} module.');
    writer.line(' * Conform to this in your Swift source code.');
    writer.line(' * Nitro may call this implementation from any native thread.');
    writer.line(' * Keep mutable state thread-safe or marshal work onto your own queue/actor.');
    writer.line(' */');
    writer.line(
      'public protocol Hybrid${spec.dartClassName}Protocol: AnyObject {',
    );

    for (final func in spec.functions) {
      if (func.lineNumber != null) {
        writer.line('    // source: ${spec.sourceUri.split('/').last}:${func.lineNumber}');
      }
      final retType = _toSwiftType(spec, func.returnType.name, bridgeType: func.returnType);
      final params = func.params.map((p) {
        if (p.type.isFunction) {
          return '${p.name}: @escaping ${_toSwiftProtocolCallbackType(spec, p.type)}';
        }
        return '${p.name}: ${_toSwiftType(spec, p.type.name, bridgeType: p.type)}';
      }).join(', ');
      if (func.isAsync || func.isNativeAsync) {
        writer.line(
          '    func ${func.dartName}($params) async throws -> $retType',
        );
      } else {
        writer.line('    func ${func.dartName}($params) -> $retType');
      }
    }

    for (final prop in spec.properties) {
      final swiftType = _toSwiftType(spec, prop.type.name);
      if (prop.hasSetter) {
        writer.line('    var ${prop.dartName}: $swiftType { get set }');
      } else {
        writer.line('    var ${prop.dartName}: $swiftType { get }');
      }
    }

    for (final stream in spec.streams) {
      final itemType = _toSwiftType(spec, stream.itemType.name);
      writer.line(
        '    var ${stream.dartName}: AnyPublisher<$itemType, Never> { get }',
      );
    }

    writer.line('}');
    writer.blankLine();

    // ── Registry — pure Swift, no @objc / NSObject needed ─────────────────
    writer.line('public class ${spec.dartClassName}Registry {');
    writer.line(
      '    public static var impl: Hybrid${spec.dartClassName}Protocol?',
    );
    writer.blankLine();
    writer.line(
      '    public static func register(_ impl: Hybrid${spec.dartClassName}Protocol) {',
    );
    writer.line('        ${spec.dartClassName}Registry.impl = impl');
    writer.line('    }');

    for (final stream in spec.streams) {
      writer.blankLine();
      writer.line(
        '    // Stream: ${stream.dartName} cancellables keyed by dartPort',
      );
      writer.line(
        '    public static var _${stream.dartName}Cancellables = [Int64: AnyCancellable]()',
      );
    }

    writer.line('}');
    writer.blankLine();

    // ── @_cdecl C bridge stubs ─────────────────────────────────────────────
    // These are exported as plain C symbols and called by the generated .cpp
    // shim via `extern "C"` declarations. @objc is NOT used because Swift
    // structs and Swift-only protocols cannot cross the ObjC boundary.
    writer.line(
      '// MARK: - C bridge stubs — exported as C symbols called by the generated .cpp shim',
    );
    writer.blankLine();

    for (final func in spec.functions) {
      if (func.lineNumber != null) {
        writer.line('// source: ${spec.sourceUri.split('/').last}:${func.lineNumber}');
      }
      final cRetType = _toCDeclReturnType(spec, func);
      // @_cdecl params must use C-ABI-compatible types.
      // Typed list params get an extra `_ <name>_length: Int64` param.
      // Function callback params are C function pointers: @convention(c) (...) -> Void.
      final params = func.params
          .expand((p) {
            if (p.type.isFunction) {
              return ['_ ${p.name}: ${_toCDeclCallbackType(p.type, spec: spec)}'];
            }
            final t = _toCDeclParamType(spec, p.type.name, bridgeType: p.type);
            if (p.type.isTypedData) {
              return ['_ ${p.name}: $t', '_ ${p.name}_length: Int64'];
            }
            return ['_ ${p.name}: $t'];
          })
          .join(', ');
      // String params arrive as UnsafePointer<CChar>? — convert to Swift String.
      final stringParams = func.params.where((p) => p.type.name == 'String' || p.type.name == 'String?').toList();
      // Typed list params arrive as raw C pointer + length — convert to Swift Array.
      final typedListParams = func.params.where((p) => p.type.isTypedData).toList();
      // Record-list params arrive as binary-encoded UnsafeMutablePointer<UInt8>? — decode to Swift Array.
      final recordListParams = func.params.where((p) => p.type.isRecord && p.type.name.startsWith('List<')).toList();
      // Pass the converted local variables for String/typed-list/record-list params.
      final callArgs = func.params
          .map((p) {
            final isString = p.type.name == 'String' || p.type.name == 'String?';
            final isBool = p.type.name == 'bool' || p.type.name == 'bool?';
            if (isString) return '${p.name}: ${p.name}Str';
            if (isBool) return '${p.name}: ${p.name} != 0';
            if (p.type.isTypedData) return '${p.name}: ${p.name}Arr';
            if (p.type.isRecord && p.type.name.startsWith('List<')) return '${p.name}: ${p.name}Decoded';
            if (p.type.isFunction) {
              return '${p.name}: ${_toSwiftCallbackWrapper(spec, p)}';
            }
            if (spec.structs.any((st) => st.name == p.type.name.replaceFirst('?', ''))) {
              final structName = p.type.name.replaceFirst('?', '');
              final isOpt = p.type.name.endsWith('?');
              // Read via C shadow struct to match C header layout exactly.
              // Swift String (16 bytes) != C const char* (8 bytes) → must use shadow.
              if (isOpt) {
                return '${p.name}: ${p.name}.map { \$0.assumingMemoryBound(to: _${structName}C.self).pointee.toSwift() }';
              } else {
                return '${p.name}: ${p.name}!.assumingMemoryBound(to: _${structName}C.self).pointee.toSwift()';
              }
            }
            if (spec.recordTypes.any((rt) => rt.name == p.type.name.replaceFirst('?', ''))) {
              final recordName = p.type.name.replaceFirst('?', '');
              return '${p.name}: $recordName.fromNative(${p.name}!.assumingMemoryBound(to: UInt8.self))';
            }
            return '${p.name}: ${p.name}';
          })
          .join(', ');
      final isStruct = spec.structs.any(
        (st) => st.name == func.returnType.name.replaceFirst('?', ''),
      );
      final isRecord = spec.recordTypes.any(
        (rt) => rt.name == func.returnType.name.replaceFirst('?', ''),
      );
      final isRecordList = func.returnType.name.startsWith('List<');
      final isBool = _toCDeclReturnType(spec, func) == 'Int8';
      final isVoid = func.returnType.name == 'void';
      final isString = func.returnType.name.replaceFirst('?', '') == 'String';
      final isTypedDataReturn = func.returnType.isTypedData;
      final isEnumRet = spec.enums.any(
        (en) => en.name == func.returnType.name.replaceFirst('?', ''),
      );

      if (func.isNativeAsync) {
        // @NitroNativeAsync — Task posts result via Dart_PostCObject_DL.
        // No semaphore: the calling C thread returns immediately; Swift Task
        // runs concurrently and posts when the async work completes.
        //
        // Dart_CObject is a C struct with an anonymous union field `value`.
        // Swift interop rules:
        //   • Always zero-init:  var obj = Dart_CObject()
        //   • Set type with named C enum constant: obj.type = Dart_CObject_kXxx
        //   • Set union field directly:           obj.value.as_string = ptr
        //   • Never use Dart_CObject(type:value:) initialiser — the anonymous
        //     union has no standalone Swift type name.
        final isVoidRet = func.returnType.name == 'void';
        writer.line('@_cdecl("_${spec.namespace}_call_${func.dartName}")');
        writer.line('public func _${spec.namespace}_call_${func.dartName}($params${params.isNotEmpty ? ", " : ""}_ dartPort: Int64) {');

        // Param conversions (same as regular async)
        for (final p in stringParams) {
          writer.line('    let ${p.name}Str = ${p.name} != nil ? String(cString: ${p.name}!) : ""');
        }
        for (final p in typedListParams) {
          final isData = p.type.name.startsWith('Uint8List') || p.type.name.startsWith('Int8List');
          if (isData) {
            writer.line('    let ${p.name}Arr = ${p.name}.map { Data(UnsafeBufferPointer(start: \$0, count: Int(${p.name}_length))) } ?? Data()');
          } else {
            writer.line('    let ${p.name}Arr = ${p.name}.map { Array(UnsafeBufferPointer(start: \$0, count: Int(${p.name}_length))) } ?? []');
          }
        }

        // Post kNull when impl is not registered.
        writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else {');
        writer.line('        var _null = Dart_CObject()');
        writer.line('        _null.type = Dart_CObject_kNull');
        writer.line('        Dart_PostCObject_DL(dartPort, &_null)');
        writer.line('        return');
        writer.line('    }');
        writer.line('    Task.detached {');
        // Use pre-defined stringParams conversions inside Task.detached
        final callArgs = func.params
            .map((p) {
              final isString = p.type.name == 'String' || p.type.name == 'String?';
              final argValue = isString ? '${p.name}Str' : p.name;
              return '${p.name}: $argValue';
            })
            .join(', ');
        if (isVoidRet) {
          writer.line('        try? await impl.${func.dartName}($callArgs)');
          writer.line('        var _null = Dart_CObject()');
          writer.line('        _null.type = Dart_CObject_kNull');
          writer.line('        Dart_PostCObject_DL(dartPort, &_null)');
        } else if (func.returnType.name == 'String') {
          writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? ""');
          writer.line('        _result.withCString { cStr in');
          writer.line('            var _obj = Dart_CObject()');
          writer.line('            _obj.type = Dart_CObject_kString');
          writer.line('            _obj.value.as_string = cStr');
          writer.line('            Dart_PostCObject_DL(dartPort, &_obj)');
          writer.line('        }');
        } else if (func.returnType.name == 'bool') {
          writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? false');
          writer.line('        var _obj = Dart_CObject()');
          writer.line('        _obj.type = Dart_CObject_kBool');
          writer.line('        _obj.value.as_bool = _result');
          writer.line('        Dart_PostCObject_DL(dartPort, &_obj)');
        } else {
          // int / double / enum — post as kInt64 / kDouble
          final isDouble = func.returnType.name == 'double';
          final isEnum = spec.enums.any((e) => e.name == func.returnType.name);
          if (isDouble) {
            writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? 0.0');
            writer.line('        var _obj = Dart_CObject()');
            writer.line('        _obj.type = Dart_CObject_kDouble');
            writer.line('        _obj.value.as_double = _result');
          } else if (isEnum) {
            writer.line('        let _result = (try? await impl.${func.dartName}($callArgs))?.rawValue ?? 0');
            writer.line('        var _obj = Dart_CObject()');
            writer.line('        _obj.type = Dart_CObject_kInt64');
            writer.line('        _obj.value.as_int64 = Int64(_result)');
          } else {
            writer.line('        let _result = (try? await impl.${func.dartName}($callArgs)) ?? 0');
            writer.line('        var _obj = Dart_CObject()');
            writer.line('        _obj.type = Dart_CObject_kInt64');
            writer.line('        _obj.value.as_int64 = Int64(_result)');
          }
          writer.line('        Dart_PostCObject_DL(dartPort, &_obj)');
        }
        writer.line('    }');
        writer.line('}');
        writer.blankLine();
        continue;
      }

      writer.line('@_cdecl("_${spec.namespace}_call_${func.dartName}")');
      writer.line('public func _${spec.namespace}_call_${func.dartName}($params) -> $cRetType {');

      // Emit UnsafePointer<CChar>? → Swift String conversions for each String param.
      for (final p in stringParams) {
        writer.line(
          '    let ${p.name}Str = ${p.name} != nil ? String(cString: ${p.name}!) : ""',
        );
      }
      // Emit UnsafeMutablePointer<T>? + length -> Data/Array for each typed-list param.
      for (final p in typedListParams) {
        final isData = p.type.name.startsWith('Uint8List') || p.type.name.startsWith('Int8List');
        if (isData) {
          writer.line('    let ${p.name}Arr = ${p.name}.map { Data(UnsafeBufferPointer(start: \$0, count: Int(${p.name}_length))) } ?? Data()');
        } else {
          writer.line('    let ${p.name}Arr = ${p.name}.map { Array(UnsafeBufferPointer(start: \$0, count: Int(${p.name}_length))) } ?? []');
        }
      }
      // Emit UnsafeMutableRawPointer? → Swift Array for binary-encoded record/struct list params.
      for (final p in recordListParams) {
        final itemType = p.type.name.substring(5, p.type.name.length - 1);
        writer.line('    let ${p.name}Ptr = ${p.name}?.assumingMemoryBound(to: UInt8.self)');
        writer.line('    let ${p.name}Decoded = ${p.name}Ptr.map { NitroRecordReader.decodeList(\$0) { r in $itemType.fromReader(r) } } ?? []');
      }

      if (func.isAsync) {
        // Async: block the calling thread with a semaphore until the Task
        // completes. Safe because callAsync() always runs on a background isolate.
        if (isStruct) {
          final retStructName = func.returnType.name.replaceFirst('?', '');
          writer.line(
            '    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }',
          );
          writer.line('    let sema = DispatchSemaphore(value: 0)');
          writer.line('    var result: ${func.returnType.name}? = nil');
          writer.line('    Task.detached {');
          writer.line(
            '        result = try? await impl.${func.dartName}($callArgs)',
          );
          writer.line('        sema.signal()');
          writer.line('    }');
          writer.line('    sema.wait()');
          writer.line('    guard let r = result else { return nil }');
          // Allocate a C-ABI shadow struct so Dart reads C-layout memory (not Swift SSO layout).
          writer.line(
            '    let ptr = UnsafeMutablePointer<_${retStructName}C>.allocate(capacity: 1)',
          );
          writer.line('    ptr.initialize(to: _${retStructName}C.fromSwift(r))');
          writer.line('    return UnsafeMutableRawPointer(ptr)');
        } else if (isVoid) {
          writer.line(
            '    guard let impl = ${spec.dartClassName}Registry.impl else { return }',
          );
          writer.line('    let sema = DispatchSemaphore(value: 0)');
          writer.line('    Task.detached {');
          writer.line('        try? await impl.${func.dartName}($callArgs)');
          writer.line('        sema.signal()');
          writer.line('    }');
          writer.line('    sema.wait()');
        } else if (isString) {
          // String result must be malloc'd (strdup) so Dart's free() works.
          writer.line(
            '    guard let impl = ${spec.dartClassName}Registry.impl else { return strdup("") }',
          );
          writer.line('    let sema = DispatchSemaphore(value: 0)');
          writer.line('    var result = ""');
          writer.line('    Task.detached {');
          writer.line(
            '        result = (try? await impl.${func.dartName}($callArgs)) ?? ""',
          );
          writer.line('        sema.signal()');
          writer.line('    }');
          writer.line('    sema.wait()');
          writer.line('    return strdup(result)');
        } else if (isRecord) {
          writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
          writer.line('    let sema = DispatchSemaphore(value: 0)');
          writer.line('    var result: ${func.returnType.name}? = nil');
          writer.line('    Task.detached {');
          writer.line('        result = try? await impl.${func.dartName}($callArgs)');
          writer.line('        sema.signal()');
          writer.line('    }');
          writer.line('    sema.wait()');
          writer.line('    return result?.toNative()');
        } else if (isRecordList) {
          writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
          writer.line('    let sema = DispatchSemaphore(value: 0)');
          writer.line('    var result: ${_toSwiftType(spec, func.returnType.name)}? = nil');
          writer.line('    Task.detached {');
          writer.line('        result = try? await impl.${func.dartName}($callArgs)');
          writer.line('        sema.signal()');
          writer.line('    }');
          writer.line('    sema.wait()');
          writer.line('    guard let r = result else { return nil }');

          final itemType = func.returnType.name.substring(5, func.returnType.name.length - 1);
          final isPrim = ['int', 'double', 'bool', 'String'].contains(itemType.replaceAll('?', ''));
          if (isPrim) {
            final base = itemType.replaceAll('?', '');
            String writeCall = 'writeInt(e)';
            if (base == 'int') writeCall = 'writeInt(e)';
            if (base == 'double') writeCall = 'writeDouble(e)';
            if (base == 'bool') writeCall = 'writeBool(e)';
            if (base == 'String') writeCall = 'writeString(e)';
            writer.line('    return NitroRecordWriter.encodeList(r) { w, e in w.$writeCall }');
          } else {
            writer.line('    return NitroRecordWriter.encodeIndexedList(r) { w, e in e.writeFields(w) }');
          }
        } else if (isTypedDataReturn) {
          final swiftRetType = _toSwiftType(spec, func.returnType.name);
          writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
          writer.line('    let sema = DispatchSemaphore(value: 0)');
          writer.line('    var result: $swiftRetType? = nil');
          writer.line('    Task.detached {');
          writer.line('        result = try? await impl.${func.dartName}($callArgs)');
          writer.line('        sema.signal()');
          writer.line('    }');
          writer.line('    sema.wait()');
          writer.line('    guard let r = result else { return nil }');
          if (_isDataBackedTypedData(func.returnType.name)) {
            final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataReturn' : '_nitroCopyTypedDataReturn';
            writer.line('    return r.withUnsafeBytes { $helper(\$0) }');
          } else {
            final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataArrayReturn' : '_nitroCopyTypedDataArrayReturn';
            writer.line('    return $helper(r)');
          }
        } else if (isBool) {
          writer.line(
            '    guard let impl = ${spec.dartClassName}Registry.impl else { return 0 }',
          );
          writer.line('    let sema = DispatchSemaphore(value: 0)');
          writer.line('    var result: Bool? = nil');
          writer.line('    Task.detached {');
          writer.line(
            '        result = try? await impl.${func.dartName}($callArgs)',
          );
          writer.line('        sema.signal()');
          writer.line('    }');
          writer.line('    sema.wait()');
          writer.line('    return Int8((result ?? false) ? 1 : 0)');
        } else {
          final swiftRetType = _toSwiftType(spec, func.returnType.name);
          final defaultVal = _defaultCDeclValue(spec, func.returnType.name);
          writer.line(
            '    guard let impl = ${spec.dartClassName}Registry.impl else { return $defaultVal }',
          );
          writer.line('    let sema = DispatchSemaphore(value: 0)');
          writer.line('    var result: $swiftRetType? = nil');
          writer.line('    Task.detached {');
          writer.line(
            '        result = try? await impl.${func.dartName}($callArgs)',
          );
          writer.line('        sema.signal()');
          writer.line('    }');
          writer.line('    sema.wait()');
          if (isEnumRet) {
            writer.line('    return result?.rawValue ?? $defaultVal');
          } else {
            writer.line('    return result ?? $defaultVal');
          }
        }
      } else if (isVoid) {
        writer.line(
          '    ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs)',
        );
      } else if (isBool) {
        writer.line(
          '    return Int8((${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) ?? false) ? 1 : 0)',
        );
      } else if (isStruct) {
        final structName = func.returnType.name.replaceFirst('?', '');
        if (func.returnType.isNullable) {
          // Double-guard: unwrap impl AND unwrap the nullable struct result.
          // impl?.method() where method returns Struct? gives Struct?? — guard let
          // only peels one layer, so split into two guards.
          writer.line(
            '    guard let impl = ${spec.dartClassName}Registry.impl, let result = impl.${func.dartName}($callArgs) else { return nil }',
          );
        } else {
          writer.line(
            '    guard let result = ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) else { return nil }',
          );
        }
        // Allocate a C-ABI shadow struct so Dart reads C-layout memory (not Swift SSO layout).
        writer.line(
          '    let ptr = UnsafeMutablePointer<_${structName}C>.allocate(capacity: 1)',
        );
        writer.line('    ptr.initialize(to: _${structName}C.fromSwift(result))');
        writer.line('    return UnsafeMutableRawPointer(ptr)');
      } else if (isString) {
        // String result must be malloc'd (strdup) so Dart's free() works.
        writer.line(
          '    return strdup(${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) ?? "")',
        );
      } else if (isRecord) {
        if (func.returnType.isNullable) {
          // Explicit impl guard to avoid Struct?? double-optional chaining.
          writer.line('    guard let impl = ${spec.dartClassName}Registry.impl else { return nil }');
          writer.line('    return impl.${func.dartName}($callArgs)?.toNative()');
        } else {
          writer.line('    return ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs)?.toNative()');
        }
      } else if (isRecordList) {
        writer.line('    guard let r = ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) else { return nil }');
        final itemType = func.returnType.name.substring(5, func.returnType.name.length - 1);
        final isPrim = ['int', 'double', 'bool', 'String'].contains(itemType.replaceAll('?', ''));
        if (isPrim) {
          final base = itemType.replaceAll('?', '');
          String writeCall = 'writeInt(e)';
          if (base == 'int') writeCall = 'writeInt(e)';
          if (base == 'double') writeCall = 'writeDouble(e)';
          if (base == 'bool') writeCall = 'writeBool(e)';
          if (base == 'String') writeCall = 'writeString(e)';
          writer.line('    return NitroRecordWriter.encodeList(r) { w, e in w.$writeCall }');
        } else {
          writer.line('    return NitroRecordWriter.encodeIndexedList(r) { w, e in e.writeFields(w) }');
        }
      } else if (isTypedDataReturn) {
        writer.line('    guard let r = ${spec.dartClassName}Registry.impl?.${func.dartName}($callArgs) else { return nil }');
        if (_isDataBackedTypedData(func.returnType.name)) {
          final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataReturn' : '_nitroCopyTypedDataReturn';
          writer.line('    return r.withUnsafeBytes { $helper(\$0) }');
        } else {
          final helper = func.zeroCopyReturn ? '_nitroMakeZeroCopyTypedDataArrayReturn' : '_nitroCopyTypedDataArrayReturn';
          writer.line('    return $helper(r)');
        }
      } else {
        final defaultVal = _defaultCDeclValue(spec, func.returnType.name);

        writer.line(
          '    guard let impl = ${spec.dartClassName}Registry.impl else { return $defaultVal }',
        );
        if (isEnumRet && func.returnType.isNullable) {
          writer.line('    return impl.${func.dartName}($callArgs)?.rawValue ?? $defaultVal');
        } else if (isEnumRet) {
          writer.line('    return impl.${func.dartName}($callArgs).rawValue');
        } else if (func.returnType.isNullable) {
          writer.line('    return impl.${func.dartName}($callArgs) ?? $defaultVal');
        } else {
          writer.line('    return impl.${func.dartName}($callArgs)');
        }
      }

      writer.line('}');
      writer.blankLine();
    }

    for (final prop in spec.properties) {
      final swiftType = _toSwiftType(spec, prop.type.name);
      final propTypeName = prop.type.name;
      final propTypeBase = propTypeName.replaceFirst('?', '');
      final isNullableProp = propTypeName.endsWith('?');
      final isBool = propTypeBase == 'bool';
      final isDouble = propTypeBase == 'double';
      final isInt = propTypeBase == 'int';
      final isString = propTypeName == 'String' || propTypeName == 'String?';
      if (prop.hasGetter) {
        final isEnumProp = spec.enums.any((en) => en.name == propTypeBase);
        // @_cdecl functions cannot use Swift optionals — nullable primitives use sentinels:
        //   double? → Double  (Double.nan = null)
        //   int?    → Int64   (-1 = null)
        //   bool?   → Int8    (-1 = null, 0 = false, 1 = true)
        //   String? → UnsafeMutablePointer<CChar>? (nullptr = null — already ObjC-safe)
        final getRetType = isString
            ? 'UnsafeMutablePointer<CChar>?'
            : isBool
            ? 'Int8'
            : isEnumProp
            ? 'Int64'
            : (isNullableProp && (isDouble || isInt))
            ? (isDouble ? 'Double' : 'Int64')
            : swiftType;
        writer.line('@_cdecl("_${spec.namespace}_call_get_${prop.dartName}")');
        writer.line('public func _${spec.namespace}_call_get_${prop.dartName}() -> $getRetType {');
        if (isString && isNullableProp) {
          writer.line(
            '    guard let v = ${spec.dartClassName}Registry.impl?.${prop.dartName} else { return nil }',
          );
          writer.line('    return strdup(v)');
        } else if (isString) {
          writer.line(
            '    return strdup(${spec.dartClassName}Registry.impl?.${prop.dartName} ?? "")',
          );
        } else if (isBool && isNullableProp) {
          // nullable bool: nil → -1, false → 0, true → 1
          writer.line(
            '    guard let v = ${spec.dartClassName}Registry.impl?.${prop.dartName} else { return -1 }',
          );
          writer.line('    return v == true ? 1 : 0');
        } else if (isBool) {
          writer.line(
            '    return ${spec.dartClassName}Registry.impl?.${prop.dartName} == true ? 1 : 0',
          );
        } else if (isEnumProp && isNullableProp) {
          writer.line(
            '    return ${spec.dartClassName}Registry.impl?.${prop.dartName}?.rawValue ?? -1',
          );
        } else if (isEnumProp) {
          writer.line(
            '    return ${spec.dartClassName}Registry.impl?.${prop.dartName}.rawValue ?? ${_defaultCDeclValue(spec, propTypeName)}',
          );
        } else if (isNullableProp && isDouble) {
          // double?: nil → Double.nan
          writer.line(
            '    return ${spec.dartClassName}Registry.impl?.${prop.dartName} ?? Double.nan',
          );
        } else if (isNullableProp && isInt) {
          // int?: nil → -1
          writer.line(
            '    return ${spec.dartClassName}Registry.impl?.${prop.dartName} ?? -1',
          );
        } else {
          writer.line(
            '    return ${spec.dartClassName}Registry.impl?.${prop.dartName} ?? ${_defaultCDeclValue(spec, propTypeName)}',
          );
        }
        writer.line('}');
        writer.blankLine();
      }
      if (prop.hasSetter) {
        final isEnumProp = spec.enums.any((en) => en.name == propTypeBase);
        final isStructProp = spec.structs.any((st) => st.name == propTypeBase);
        // @_cdecl setters must not use Swift optional parameter types.
        // Nullable primitives use sentinels matching the getter convention.
        final setParamType = isBool
            ? 'Int8'
            : isString
            ? 'UnsafePointer<CChar>?'   // nullable String: nullptr = null
            : isEnumProp
            ? 'Int64'
            : isStructProp
            ? 'UnsafeRawPointer?'
            : (isNullableProp && isDouble)
            ? 'Double'      // nullable double: Double.nan = null
            : (isNullableProp && isInt)
            ? 'Int64'       // nullable int: -1 = null
            : swiftType;
        writer.line('@_cdecl("_${spec.namespace}_call_set_${prop.dartName}")');
        writer.line(
          'public func _${spec.namespace}_call_set_${prop.dartName}(_ value: $setParamType) {',
        );
        if (isBool && isNullableProp) {
          // nullable bool: -1 = null, 0 = false, 1 = true
          writer.line(
            '    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value == -1 ? nil : value != 0',
          );
        } else if (isBool) {
          writer.line(
            '    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value != 0',
          );
        } else if (isString && isNullableProp) {
          writer.line(
            '    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value != nil ? String(cString: value!) : nil',
          );
        } else if (isString) {
          writer.line(
            '    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value != nil ? String(cString: value!) : ""',
          );
        } else if (isEnumProp && isNullableProp) {
          // nullable enum: -1 = null
          writer.line('    if value == -1 { ${spec.dartClassName}Registry.impl?.${prop.dartName} = nil; return }');
          writer.line(
            '    if let actualValue = ${propTypeBase}(rawValue: value) {',
          );
          writer.line('        ${spec.dartClassName}Registry.impl?.${prop.dartName} = actualValue');
          writer.line('    }');
        } else if (isEnumProp) {
          writer.line(
            '    if let actualValue = ${propTypeBase}(rawValue: value) {',
          );
          writer.line('        ${spec.dartClassName}Registry.impl?.${prop.dartName} = actualValue');
          writer.line('    }');
        } else if (isStructProp) {
          final propStructName = propTypeBase;
          writer.line(
            '    if let v = value {',
          );
          // Use C shadow struct to read C-layout memory correctly.
          writer.line('        ${spec.dartClassName}Registry.impl?.${prop.dartName} = v.assumingMemoryBound(to: _${propStructName}C.self).pointee.toSwift()');
          writer.line('    }');
        } else if (isNullableProp && isDouble) {
          // double?: NaN = null
          writer.line(
            '    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value.isNaN ? nil : value',
          );
        } else if (isNullableProp && isInt) {
          // int?: -1 = null
          writer.line(
            '    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value == -1 ? nil : value',
          );
        } else {
          writer.line(
            '    ${spec.dartClassName}Registry.impl?.${prop.dartName} = value',
          );
        }
        writer.line('}');
        writer.blankLine();
      }
    }

    for (final stream in spec.streams) {
      final cType = _toSwiftCType(spec, stream.itemType.name);
      final itemName = stream.itemType.name.replaceFirst('?', '');
      final isStructItem = spec.structs.any((st) => st.name == itemName);
      final isRecordItem = stream.itemType.isRecord;
      final isEnumItem = spec.enums.any((en) => en.name == itemName);
      writer.line('@_cdecl("_${spec.namespace}_register_${stream.dartName}_stream")');
      writer.line('public func _${spec.namespace}_register_${stream.dartName}_stream(');
      writer.line('    _ dartPort: Int64,');
      writer.line('    _ emitCb: @convention(c) (Int64, $cType) -> Bool');
      writer.line(') {');
      writer.line(
        '    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort] =',
      );
      writer.line(
        '        ${spec.dartClassName}Registry.impl?.${stream.dartName}.sink { item in',
      );
      if (isStructItem) {
        // Allocate a C-ABI shadow struct so Dart reads correct memory layout.
        writer.line(
          '            let ptr = UnsafeMutablePointer<_${itemName}C>.allocate(capacity: 1)',
        );
        writer.line('            ptr.initialize(to: _${itemName}C.fromSwift(item))');
        writer.line('            if !emitCb(dartPort, UnsafeMutableRawPointer(ptr)) {');
        writer.line('                ptr.deinitialize(count: 1)');
        writer.line('                ptr.deallocate()');
        writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('            }');
      } else if (isEnumItem) {
        writer.line('            if !emitCb(dartPort, item.rawValue) {');
        writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('            }');
      } else if (isRecordItem) {
        writer.line('            let raw = item.toNative()');
        writer.line('            if !emitCb(dartPort, raw) {');
        writer.line('                if let raw { free(UnsafeMutableRawPointer(raw)) }');
        writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('            }');
      } else {
        writer.line('            if !emitCb(dartPort, item) {');
        writer.line('                ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)?.cancel()');
        writer.line('            }');
      }
      writer.line('        }');
      writer.line('}');
      writer.blankLine();
      writer.line('@_cdecl("_${spec.namespace}_release_${stream.dartName}_stream")');
      writer.line(
        'public func _${spec.namespace}_release_${stream.dartName}_stream(_ dartPort: Int64) {',
      );
      writer.line(
        '    ${spec.dartClassName}Registry._${stream.dartName}Cancellables[dartPort]?.cancel()',
      );
      writer.line(
        '    ${spec.dartClassName}Registry._${stream.dartName}Cancellables.removeValue(forKey: dartPort)',
      );
      writer.line('}');
    }

    return writer.toString();
  }

  /// Generates Swift type declarations for a type-only .native.dart file.
  /// Emits only enum/struct/record declarations — no protocol, registry, or @_cdecl stubs.
  static String _generateTypeOnly(BridgeSpec spec) {
    final nodes = <CodeNode>[
      CodeSnippet(generatedFileHeader('//', sourceUri: spec.sourceUri)),
      const CodeLine('import Foundation'),
      const BlankLine(),
    ];

    final swiftEnums = EnumGenerator.generateSwift(spec);
    if (swiftEnums.isNotEmpty) nodes.add(CodeSnippet(swiftEnums));

    final swiftStructs = StructGenerator.generateSwift(spec);
    if (swiftStructs.isNotEmpty) nodes.add(CodeSnippet(swiftStructs));

    final swiftRecords = RecordGenerator.generateSwift(spec);
    if (swiftRecords.isNotEmpty) nodes.add(CodeSnippet(swiftRecords));

    return CodeFile(nodes).render();
  }

  /// Generates a reduced Swift bridge for [NativeImpl.cpp] modules.
  ///
  /// C++ modules use the `.mm` shim (which calls `mylib_xxx` C functions from
  /// the generated `.bridge.g.cpp`). They do NOT use `@_cdecl` Swift stubs:
  ///
  /// - The C++ bridge never calls `_call_add` etc. — it calls `mylib_add`.
  /// - Emitting `@_cdecl("_call_add")` here would duplicate the symbol
  ///   already exported by the Swift (non-cpp) module's bridge, causing a
  ///   "duplicate symbol" Swift compiler error when both are in the same target.
  /// - Shared types (BenchmarkPoint, BenchmarkBox, NitroRecordWriter, etc.)
  ///   are already declared in the Swift module's `.bridge.g.swift`. Both
  ///   files are compiled into the same Swift module, so redeclaring them
  ///   causes "Invalid redeclaration of '…'" errors.
  ///
  /// This method only emits the protocol and registry — everything the user
  /// needs to implement and register their C++ class in Swift/ObjC++.
  static String _generateCppModuleBridge(BridgeSpec spec) {
    final nodes = <CodeNode>[
      CodeSnippet(generatedFileHeader('//', sourceUri: spec.sourceUri)),
      const CodeLine('import Foundation'),
      const CodeLine('import Combine'),
      const BlankLine(),
      const CodeLine(
        '// Shared types (structs, NitroRecordWriter, NitroRecordReader) are declared',
      ),
      const CodeLine(
        '// in the Swift module\'s .bridge.g.swift — compiled into the same module.',
      ),
      const CodeLine('// Do NOT redeclare them here.'),
      const CodeLine('//'),
      const CodeLine(
        '// No @_cdecl stubs are generated: the C++ bridge (.bridge.g.mm) calls',
      ),
      CodeLine(
        '// ${spec.namespace}_xxx C functions directly — Swift @_cdecl stubs are unused',
      ),
      const CodeLine(
        '// and would conflict with the Swift module\'s exported symbols.',
      ),
      const BlankLine(),
    ];

    final swiftEnums = EnumGenerator.generateSwift(spec);
    if (swiftEnums.isNotEmpty) nodes.add(CodeSnippet(swiftEnums));

    final swiftStructs = StructGenerator.generateSwift(spec);
    if (swiftStructs.isNotEmpty) nodes.add(CodeSnippet(swiftStructs));

    final swiftRecords = RecordGenerator.generateSwift(spec, emitBoilerplate: false);
    if (swiftRecords.isNotEmpty) nodes.add(CodeSnippet(swiftRecords));

    // Protocol
    nodes.addAll([
      const CodeLine('/**'),
      CodeLine(' * Protocol for the ${spec.dartClassName} module (NativeImpl.cpp).'),
      const CodeLine(
        ' * Conform to this in your Swift/ObjC++ source code if you want',
      ),
      const CodeLine(
        ' * to delegate from the C++ HybridObject to a Swift implementation.',
      ),
      const CodeLine(' * Nitro may call this implementation from any native thread.'),
      const CodeLine(
        ' * Keep mutable state thread-safe or marshal work onto your own queue/actor.',
      ),
      const CodeLine(' */'),
      CodeLine('public protocol Hybrid${spec.dartClassName}Protocol: AnyObject {'),
    ]);

    for (final func in spec.functions) {
      final retType = _toSwiftType(spec, func.returnType.name);
      final params = func.params.map((p) => '${p.name}: ${_toSwiftType(spec, p.type.name)}').join(', ');
      if (func.isAsync || func.isNativeAsync) {
        nodes.add(
          CodeLine('    func ${func.dartName}($params) async throws -> $retType'),
        );
      } else {
        nodes.add(CodeLine('    func ${func.dartName}($params) -> $retType'));
      }
    }
    for (final prop in spec.properties) {
      final swiftType = _toSwiftType(spec, prop.type.name);
      if (prop.hasSetter) {
        nodes.add(CodeLine('    var ${prop.dartName}: $swiftType { get set }'));
      } else {
        nodes.add(CodeLine('    var ${prop.dartName}: $swiftType { get }'));
      }
    }
    for (final stream in spec.streams) {
      final itemType = _toSwiftType(spec, stream.itemType.name);
      nodes.add(
        CodeLine(
          '    var ${stream.dartName}: AnyPublisher<$itemType, Never> { get }',
        ),
      );
    }
    nodes.addAll(const [
      CodeLine('}'),
      BlankLine(),
    ]);

    // Registry
    nodes.addAll([
      CodeLine('public class ${spec.dartClassName}Registry {'),
      CodeLine('    public static var impl: Hybrid${spec.dartClassName}Protocol?'),
      const BlankLine(),
      CodeLine(
        '    public static func register(_ impl: Hybrid${spec.dartClassName}Protocol) {',
      ),
      CodeLine('        ${spec.dartClassName}Registry.impl = impl'),
      const CodeLine('    }'),
    ]);
    for (final stream in spec.streams) {
      nodes.add(const BlankLine());
      nodes.add(
        CodeLine('    // Stream: ${stream.dartName} cancellables keyed by dartPort'),
      );
      nodes.add(
        CodeLine(
          '    public static var _${stream.dartName}Cancellables = [Int64: AnyCancellable]()',
        ),
      );
    }
    nodes.addAll([
      const CodeLine('}'),
      const BlankLine(),
      const CodeLine(
        '// NOTE: @_cdecl bridge stubs are NOT generated for NativeImpl.cpp modules.',
      ),
      CodeLine(
        '// The .bridge.g.mm C++ shim calls ${spec.namespace}_xxx() C functions directly.',
      ),
    ]);

    return CodeFile(nodes).render();
  }

  /// Generates the idiomatic Swift closure type for a function callback parameter
  /// in the protocol declaration, e.g. `(TorchState) -> Void`.
  static String _toSwiftProtocolCallbackType(BridgeSpec spec, BridgeType cbType) {
    final retType = cbType.functionReturnType ?? 'void';
    final params = cbType.functionParams;
    // Each param uses its idiomatic Swift type: TorchLevel (struct), TorchState (enum), etc.
    final paramList = params.map((p) => _toSwiftType(spec, p.name, bridgeType: p)).join(', ');
    final retSwift = _toSwiftType(spec, retType);
    return '($paramList) -> $retSwift';
  }

  /// Generates the `@convention(c)` C function pointer type for a callback param
  /// in a `@_cdecl` stub. Uses type-specific C ABI types so the Swift compiler
  /// allocates args in the correct registers (FP for doubles, GP for integers).
  static String _toCDeclCallbackType(BridgeType cbType, {BridgeSpec? spec}) {
    final paramList = cbType.functionParams.map((t) => _callbackParamToCDeclSwift(t, spec: spec)).join(', ');
    return '@convention(c) ($paramList) -> Void';
  }

  /// Maps a single callback parameter to its Swift `@convention(c)` C ABI type.
  static String _callbackParamToCDeclSwift(BridgeType t, {BridgeSpec? spec}) {
    final base = t.name.replaceFirst('?', '');
    switch (base) {
      case 'int':
        return 'Int64';
      case 'double':
        return 'Double';
      case 'bool':
        return 'Bool';
      case 'String':
        return 'UnsafePointer<CChar>?';
      default:
        if (spec != null && spec.structs.any((s) => s.name == base)) {
          return 'UnsafeRawPointer?';             // @HybridStruct: pointer to C-layout struct
        }
        if (spec != null && spec.recordTypes.any((r) => r.name == base)) {
          return 'UnsafeMutablePointer<UInt8>?';  // @HybridRecord: length-prefixed buffer
        }
        return 'Int64'; // enum rawValue
    }
  }

  /// Generates a Swift closure that wraps the raw C function pointer received in
  /// a `@_cdecl` stub and converts each argument FROM the idiomatic Swift protocol
  /// type TO the C ABI type before calling the C function pointer.
  ///
  /// E.g. for `void Function(TorchState)`:
  ///   - The closure is passed to `impl.onCallback(callback:)` where the protocol
  ///     expects `(TorchState) -> Void`, so `arg0` is `TorchState`.
  ///   - The C function pointer expects `Int64`, so we convert via `arg0.rawValue`.
  ///   - Generated: `{ arg0 in callback(arg0.rawValue) }`
  static String _toSwiftCallbackWrapper(BridgeSpec spec, BridgeParam p) {
    final cbType = p.type;
    final cbName = p.name;
    final params = cbType.functionParams;
    if (params.isEmpty) {
      return '{ $cbName() }';
    }
    final argNames = List.generate(params.length, (i) => 'arg$i');
    final argDecl = argNames.join(', ');
    // Build per-arg conversions. Struct args need a named shadow variable so that
    // `&shadow` is valid (points to a live stack slot) when the C callback runs.
    // Non-struct conversions are inline expressions in the call args list.
    final shadowDecls = <String>[];
    final callArgs = params.asMap().entries.map((e) {
      final i = e.key;
      final pt = e.value;
      final argVar = argNames[i];
      final base = pt.name.replaceFirst('?', '');
      final isEnum = spec.enums.any((en) => en.name == base);
      if (isEnum) return '$argVar.rawValue';          // EnumType → Int64
      if (base == 'String') {
        return '($argVar as NSString).utf8String';    // String → UnsafePointer<CChar>?
      }
      final isStruct = spec.structs.any((s) => s.name == base);
      if (isStruct) {
        // Declare a shadow struct on the stack; &shadow is valid until the
        // enclosing closure scope exits, which is after callback() returns.
        shadowDecls.add('var _s$i = _${base}C.fromSwift($argVar)');
        return 'UnsafeRawPointer(&_s$i)';            // &shadow → UnsafeRawPointer?
      }
      final isRecord = spec.recordTypes.any((r) => r.name == base);
      if (isRecord) {
        // Serialize record to a malloc'd length-prefixed buffer via toNative().
        // Dart receives the pointer and frees it after fromNative() reads it.
        return '$argVar.toNative()';                  // UnsafeMutablePointer<UInt8>?
      }
      return argVar;                                  // int, double, bool
    }).toList();

    // If there are shadow-variable declarations, emit them as statements
    // separated by semicolons before the call, all within the closure body.
    final closureBody = shadowDecls.isEmpty
        ? '$cbName(${callArgs.join(', ')})'
        : '${shadowDecls.join('; ')}; $cbName(${callArgs.join(', ')})';
    return '{ $argDecl in $closureBody }';
  }

  /// Return type for a `@_cdecl` function — must be a C-ABI-compatible type.
  /// - `void`   → `Void`
  /// - `bool`   → `Int8`
  /// - `String` → `UnsafeMutablePointer<CChar>?`  (malloc'd; Dart calls free())
  /// - struct   → `UnsafeMutableRawPointer?`       (heap-allocated Swift struct)
  /// - others   → same as `_toSwiftType`
  static String _toCDeclReturnType(BridgeSpec spec, BridgeFunction func) {
    // NativeHandle<T> is a raw opaque pointer — same C type as void*.
    if (func.returnType.isNativeHandle) return 'UnsafeMutableRawPointer?';
    final name = func.returnType.name.replaceFirst('?', '');
    if (name == 'void') return 'Void';
    if (name == 'bool') return 'Int8';
    if (name == 'String') return 'UnsafeMutablePointer<CChar>?';
    if (BridgeType(name: name).isTypedData) return 'UnsafeMutablePointer<UInt8>?';
    if (spec.structs.any((st) => st.name == name)) {
      return 'UnsafeMutableRawPointer?';
    }
    if (spec.recordTypes.any((rt) => rt.name == name) || name.startsWith('List<')) {
      return 'UnsafeMutableRawPointer?';
    }
    final isEnumRet = spec.enums.any((en) => en.name == name);
    if (isEnumRet) return 'Int64';
    return _toSwiftType(spec, name);
  }

  /// Parameter type for a `@_cdecl` function — must be a C-ABI-compatible type.
  /// - `String`     → `UnsafePointer<CChar>?`  (C `const char*`)
  /// - `bool`       → `Int8`
  /// - typed lists  → `UnsafeMutablePointer<T>?`  (raw C pointer; length passed separately)
  /// - others       → same as `_toSwiftType`
  static String _toCDeclParamType(BridgeSpec spec, String typeName, {BridgeType? bridgeType}) {
    // NativeHandle<T> passes as an opaque raw pointer.
    if (bridgeType?.isNativeHandle == true) return 'UnsafeMutableRawPointer?';
    final name = typeName.replaceFirst('?', '');
    if (name == 'String') return 'UnsafePointer<CChar>?';
    if (name == 'bool') return 'Int8';
    if (spec.recordTypes.any((rt) => rt.name == name) || name.startsWith('List<')) {
      return 'UnsafeMutableRawPointer?';
    }
    final isEnum = spec.enums.any((en) => en.name == name);
    if (isEnum) return 'Int64';
    if (spec.structs.any((st) => st.name == name)) {
      return 'UnsafeRawPointer?';
    }
    // Typed lists: use C-compatible pointer; length is passed as a separate Int64 param.
    if (BridgeType(name: name).isTypedData) {
      return _toSwiftCType(spec, name, isZeroCopy: true);
    }
    return _toSwiftType(spec, name);
  }

  static String _toSwiftType(BridgeSpec spec, String t, {BridgeType? bridgeType}) {
    final name = t.replaceFirst('?', '');
    final isOptional = t.endsWith('?');

    // NativeHandle<T> bridges as UnsafeMutableRawPointer? across Swift @_cdecl.
    if (bridgeType?.isNativeHandle == true) return 'UnsafeMutableRawPointer?';

    // Handle function types (callbacks)
    if (bridgeType != null && bridgeType.isFunction) {
      final returnType = bridgeType.functionReturnType ?? 'Void';
      final params = bridgeType.functionParams;
      final paramList = params
          .asMap()
          .entries
          .map((entry) {
            final p = entry.value;
            final swiftType = _toSwiftType(spec, p.name, bridgeType: p);
            return '_: $swiftType';
          })
          .join(', ');
      final swiftReturnType = _toSwiftType(spec, returnType);
      return '($paramList) -> $swiftReturnType';
    }

    String baseType;
    switch (name) {
      case 'int':
        baseType = 'Int64';
        break;
      case 'double':
        baseType = 'Double';
        break;
      case 'bool':
        baseType = 'Bool';
        break;
      case 'String':
        baseType = 'String';
        break;
      case 'void':
        baseType = 'Void';
        break;
      case 'Uint8List':
      case 'Int8List':
        baseType = 'Data';
        break;
      case 'Int16List':
      case 'Uint16List':
        baseType = '[Int16]';
        break;
      case 'Int32List':
      case 'Uint32List':
        baseType = '[Int32]';
        break;
      case 'Float32List':
        baseType = '[Float]';
        break;
      case 'Float64List':
        baseType = '[Double]';
        break;
      case 'Int64List':
      case 'Uint64List':
        baseType = '[Int64]';
        break;
      default:
        if (spec.enums.any((en) => en.name == name)) {
          baseType = name;
        } else if (spec.structs.any((st) => st.name == name)) {
          baseType = name;
        } else if (spec.recordTypes.any((rt) => rt.name == name)) {
          baseType = name;
        } else if (name.startsWith('List<')) {
          final itemType = name.substring(5, name.length - 1);
          baseType = '[${_toSwiftType(spec, itemType)}]';
        } else {
          baseType = 'Any';
        }
    }
    return isOptional ? '$baseType?' : baseType;
  }

  static String _toSwiftCType(BridgeSpec spec, String t, {bool isZeroCopy = false}) {
    final name = t.replaceFirst('?', '');
    switch (name) {
      case 'int':
        return 'Int64';
      case 'double':
        return 'Double';
      case 'bool':
        return 'Int8';
      case 'String':
        return 'UnsafeMutablePointer<Int8>?';
      case 'void':
        return 'Void';
      case 'Uint8List':
        return 'UnsafeMutablePointer<UInt8>?';
      case 'Int8List':
        return 'UnsafeMutablePointer<Int8>?';
      case 'Int16List':
        return 'UnsafeMutablePointer<Int16>?';
      case 'Uint16List':
        return 'UnsafeMutablePointer<UInt16>?';
      case 'Int32List':
        return 'UnsafeMutablePointer<Int32>?';
      case 'Uint32List':
        return 'UnsafeMutablePointer<UInt32>?';
      case 'Float32List':
        return isZeroCopy ? 'UnsafeMutablePointer<Float>?' : '[Float]';
      case 'Float64List':
        return isZeroCopy ? 'UnsafeMutablePointer<Double>?' : '[Double]';
      case 'Int64List':
      case 'Uint64List':
        return isZeroCopy ? 'UnsafeMutablePointer<Int64>?' : '[Int64]';
      default:
        if (spec.enums.any((en) => en.name == name)) return 'Int64';
        if (spec.structs.any((st) => st.name == name)) {
          return 'UnsafeMutableRawPointer?';
        }
        if (spec.recordTypes.any((rt) => rt.name == name) || name.startsWith('List<')) {
          return 'UnsafeMutablePointer<UInt8>?';
        }
        return 'Any?';
    }
  }

  static String _defaultCDeclValue(BridgeSpec spec, String t) {
    final name = t.replaceFirst('?', '');
    switch (name) {
      case 'int':
        return '0';
      case 'double':
        return '0.0';
      case 'bool':
        return '0';
      case 'String':
        return 'strdup("")';
      default:
        if (spec.enums.any((en) => en.name == name)) return '0';
        if (spec.structs.any((st) => st.name == name)) return 'nil';
        return '()';
    }
  }

  static bool _isDataBackedTypedData(String t) {
    final name = t.replaceFirst('?', '');
    return name == 'Uint8List' || name == 'Int8List';
  }
}
