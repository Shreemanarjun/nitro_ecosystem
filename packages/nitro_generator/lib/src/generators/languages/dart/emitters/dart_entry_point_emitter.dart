part of '../dart_ffi_generator.dart';

/// `@NitroEntryPoint` support: a typed `run<Name>InBackground(...)` per entry
/// and the `@pragma('vm:entry-point')` wrapper a headless engine starts at.
///
/// Arguments and results cross the process-wide C++ job table as one blob in
/// the record wire format (`RecordWriter`/`RecordReaderBase`), so every type
/// a record field or function parameter can carry by value is supported; the
/// codec below is name-driven and recursive (lists of lists, maps of records).
void emitEntryPointSection(CodeWriter w, BridgeSpec spec) {
  if (spec.entryPoints.isEmpty) return;
  final lib = spec.lib.replaceAll('-', '_');
  final cls = spec.dartClassName;
  w.blankLine();
  w.line('// ── @NitroEntryPoint background invocation ──────────────────────────────');
  w.line('// The job table lives in the C bridge; these bindings need no instance so');
  w.line('// the wrapper can run on a fresh isolate or a headless engine.');
  w.line('final DynamicLibrary _nitroBgDylib = _${cls}Impl._loadSupportedLibrary();');
  w.line('bool _nitroBgApiReady = false;');
  w.line('void _nitroBgEnsureApi() {');
  w.line('  if (_nitroBgApiReady) return;');
  w.line("  _nitroBgDylib.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('${lib}_init_dart_api_dl')(NativeApi.initializeApiDLData);");
  w.line('  _nitroBgApiReady = true;');
  w.line('}');
  w.line("final _nitroBgSubmit = _nitroBgDylib.lookupFunction<Int64 Function(Pointer<Utf8>, Pointer<Uint8>, Int64, Int64, Pointer<Int8>), int Function(Pointer<Utf8>, Pointer<Uint8>, int, int, Pointer<Int8>)>('${lib}_bg_submit');");
  w.line("final _nitroBgHasHost = _nitroBgDylib.lookupFunction<Int8 Function(), int Function()>('${lib}_bg_has_host');");
  w.line("final _nitroBgTake = _nitroBgDylib.lookupFunction<Pointer<Uint8> Function(Pointer<Utf8>, Int64, Pointer<Int64>, Pointer<Int64>), Pointer<Uint8> Function(Pointer<Utf8>, int, Pointer<Int64>, Pointer<Int64>)>('${lib}_bg_take_job');");
  w.line("final _nitroBgActiveCount = _nitroBgDylib.lookupFunction<Int64 Function(), int Function()>('${lib}_bg_active_count');");
  w.line("final _nitroBgComplete = _nitroBgDylib.lookupFunction<Int8 Function(Int64, Pointer<Uint8>, Int64), int Function(int, Pointer<Uint8>, int)>('${lib}_bg_complete');");
  w.line("final _nitroBgFail = _nitroBgDylib.lookupFunction<Int8 Function(Int64, Pointer<Utf8>, Pointer<Utf8>), int Function(int, Pointer<Utf8>, Pointer<Utf8>)>('${lib}_bg_fail');");
  w.line("final _nitroBgFree = _nitroBgDylib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('${lib}_nitro_free');");
  final hasStreams = spec.entryPoints.any((e) => e.isStream);
  if (hasStreams) {
    w.line("final _nitroBgEmit = _nitroBgDylib.lookupFunction<Int8 Function(Int64, Pointer<Uint8>, Int64), int Function(int, Pointer<Uint8>, int)>('${lib}_bg_emit');");
    w.line("final _nitroBgEnd = _nitroBgDylib.lookupFunction<Int8 Function(Int64), int Function(int)>('${lib}_bg_end');");
    w.line("final _nitroBgCancel = _nitroBgDylib.lookupFunction<Int8 Function(Int64), int Function(int)>('${lib}_bg_cancel');");
  }
  w.blankLine();
  w.line('/// True when the native host can start a headless engine for entry points');
  w.line('/// (Android/iOS with a Kotlin/Swift bridge). Otherwise they run on a spawned');
  w.line('/// isolate of this process — same code, no engine.');
  w.line('bool has${cls}BackgroundHost() => _nitroBgHasHost() != 0;');
  w.blankLine();
  w.line('/// Background jobs of this library submitted from any isolate or engine of');
  w.line('/// this process that have not finished yet (queued + running). Reaches 0');
  w.line('/// once every job completed, failed, or was cancelled.');
  w.line('int active${cls}BackgroundJobs() => _nitroBgActiveCount();');
  w.blankLine();
  w.line('({int jobId, Uint8List args})? _nitroBgTakeJob(String entry, int jobId) {');
  w.line('  _nitroBgEnsureApi();');
  w.line('  return using((arena) {');
  w.line('    final idOut = arena<Int64>();');
  w.line('    final lenOut = arena<Int64>();');
  w.line('    final ptr = _nitroBgTake(entry.toNativeUtf8(allocator: arena), jobId, idOut, lenOut);');
  w.line('    if (ptr == nullptr) {');
  w.line('      return null;');
  w.line('    }');
  w.line('    final args = Uint8List.fromList(ptr.asTypedList(lenOut.value));');
  w.line('    _nitroBgFree(ptr.cast());');
  w.line('    return (jobId: idOut.value, args: args);');
  w.line('  });');
  w.line('}');
  w.blankLine();
  w.line('void _nitroBgCompleteJob(int jobId, Uint8List result) => using((arena) {');
  w.line('  final buf = arena<Uint8>(result.length + 1);');
  w.line('  if (result.isNotEmpty) {');
  w.line('    buf.asTypedList(result.length).setAll(0, result);');
  w.line('  }');
  w.line('  _nitroBgComplete(jobId, buf, result.length);');
  w.line('});');
  w.blankLine();
  w.line('void _nitroBgFailJob(int jobId, String error, String stackTrace) => using((arena) {');
  w.line('  _nitroBgFail(jobId, error.toNativeUtf8(allocator: arena), stackTrace.toNativeUtf8(allocator: arena));');
  w.line('});');
  w.blankLine();
  w.line('int _nitroBgSubmitJob(String entry, void Function(List<String>) wrapper, Uint8List args, int port) {');
  w.line('  return using((arena) {');
  w.line('    final buf = arena<Uint8>(args.length + 1);');
  w.line('    if (args.isNotEmpty) {');
  w.line('      buf.asTypedList(args.length).setAll(0, args);');
  w.line('    }');
  w.line('    final started = arena<Int8>();');
  w.line('    final id = _nitroBgSubmit(entry.toNativeUtf8(allocator: arena), buf, args.length, port, started);');
  w.line('    // No host engine registered: run the same wrapper on a fresh isolate.');
  w.line('    if (started.value == 0) {');
  w.line('      NitroBackground.spawnFallback(wrapper, id);');
  w.line('    }');
  w.line('    return id;');
  w.line('  });');
  w.line('}');
  w.blankLine();
  if (hasStreams) {
    w.line('bool _nitroBgEmitItem(int jobId, Uint8List item) => using((arena) {');
    w.line('  final buf = arena<Uint8>(item.length + 1);');
    w.line('  if (item.isNotEmpty) {');
    w.line('    buf.asTypedList(item.length).setAll(0, item);');
    w.line('  }');
    w.line('  return _nitroBgEmit(jobId, buf, item.length) != 0;');
    w.line('});');
    w.blankLine();
    w.line('void _nitroBgEndJob(int jobId) => _nitroBgEnd(jobId);');
    w.blankLine();
    w.line('Stream<R> _nitroBgStream<R>(String entry, void Function(List<String>) wrapper, Uint8List args, R Function(RecordReaderBase r) decode) {');
    w.line('  _nitroBgEnsureApi();');
    w.line('  return NitroBackground.openStream<R>(');
    w.line('    entry: entry,');
    w.line('    submit: (port) => _nitroBgSubmitJob(entry, wrapper, args, port),');
    w.line('    cancel: (jobId) => _nitroBgCancel(jobId),');
    w.line('    decode: (blob) => decode(RecordReaderBase.fromPayload(blob)),');
    w.line('  );');
    w.line('}');
    w.blankLine();
  }
  w.line('Future<R> _nitroBgRun<R>(String entry, void Function(List<String>) wrapper, Uint8List args, R Function(RecordReaderBase r) decode) {');
  w.line('  _nitroBgEnsureApi();');
  w.line('  return NitroRuntime.openNativeAsync<R>(');
  w.line("    methodName: '\$entry (background)',");
  w.line('    call: (port) => _nitroBgSubmitJob(entry, wrapper, args, port),');
  w.line('    unpack: (raw) {');
  w.line('      // Success posts the result blob as Uint8 typed data (itself a List<int>);');
  w.line('      // failure posts [error, stackTrace, entry] as a List<String>.');
  w.line('      if (raw is Uint8List) {');
  w.line('        return decode(RecordReaderBase.fromPayload(raw));');
  w.line('      }');
  w.line('      throw NitroBackgroundException.fromPost(entry, raw);');
  w.line('    },');
  w.line('  );');
  w.line('}');

  final codec = _EntryCodec(spec);
  for (final e in spec.entryPoints) {
    final sig = entryPointSignature(e);
    final call = entryPointCallArgs(e);
    final ret = e.returnsVoid ? 'void' : e.returnType.name;
    w.blankLine();
    if (e.isStream) {
      w.line('/// Streams [${e.name}]\'s items from the background — a headless engine on');
      w.line('/// Android/iOS, a spawned isolate elsewhere. Cancelling stops the producer.');
      w.line('Stream<$ret> ${e.runnerName}($sig) {');
      w.line('  final w = RecordWriter();');
      for (final p in e.params) {
        w.raw(codec.write(p.type.name, p.name, '  '));
      }
      w.line("  return _nitroBgStream<$ret>('${e.name}', ${e.wrapperName}, Uint8List.fromList(w.payloadView()), (r) {");
      w.line('    return ${codec.read(e.returnType.name)};');
      w.line('  });');
      w.line('}');
      w.blankLine();
      w.line('/// Entry a headless engine (or the fallback isolate) starts at with the');
      w.line('/// job id as its only argument. Keeps [${e.name}] alive under AOT; never');
      w.line('/// call it yourself.');
      w.line("@pragma('vm:entry-point')");
      w.line('void ${e.wrapperName}(List<String> entryArgs) {');
      w.line('  final jobId = NitroBackground.jobIdOf(entryArgs);');
      w.line('  NitroBackground.runStreamEntry(');
      w.line("    entry: '${e.name}',");
      w.line("    takeJob: () => _nitroBgTakeJob('${e.name}', jobId),");
      w.line('    emit: _nitroBgEmitItem,');
      w.line('    end: _nitroBgEndJob,');
      w.line('    fail: _nitroBgFailJob,');
      w.line('    body: (args) {');
      if (e.params.isNotEmpty) {
        w.line('      final r = RecordReaderBase.fromPayload(args);');
      }
      for (final p in e.params) {
        w.line('      final ${p.name} = ${codec.read(p.type.name)};');
      }
      w.line('      return ${e.name}($call).map((item) {');
      w.line('        final w = RecordWriter();');
      w.raw(codec.write(e.returnType.name, 'item', '        '));
      w.line('        return Uint8List.fromList(w.payloadView());');
      w.line('      });');
      w.line('    },');
      w.line('  );');
      w.line('}');
      continue;
    }
    w.line('/// Runs [${e.name}] in the background — a headless engine on Android/iOS,');
    w.line('/// a spawned isolate elsewhere — and returns its result.');
    w.line('Future<$ret> ${e.runnerName}($sig) {');
    w.line('  final w = RecordWriter();');
    for (final p in e.params) {
      w.raw(codec.write(p.type.name, p.name, '  '));
    }
    w.line("  return _nitroBgRun<$ret>('${e.name}', ${e.wrapperName}, Uint8List.fromList(w.payloadView()), (r) {");
    if (e.returnsVoid) {
      w.line('    return;');
    } else {
      w.line('    return ${codec.read(e.returnType.name)};');
    }
    w.line('  });');
    w.line('}');
    w.blankLine();
    w.line('/// Entry a headless engine (or the fallback isolate) starts at with the');
    w.line('/// job id as its only argument. Keeps [${e.name}] alive under AOT; never');
    w.line('/// call it yourself.');
    w.line("@pragma('vm:entry-point')");
    w.line('void ${e.wrapperName}(List<String> entryArgs) {');
    w.line('  final jobId = NitroBackground.jobIdOf(entryArgs);');
    w.line('  NitroBackground.runEntry(');
    w.line("    entry: '${e.name}',");
    w.line("    takeJob: () => _nitroBgTakeJob('${e.name}', jobId),");
    w.line('    complete: _nitroBgCompleteJob,');
    w.line('    fail: _nitroBgFailJob,');
    w.line('    body: (args) async {');
    if (e.params.isNotEmpty) {
      w.line('      final r = RecordReaderBase.fromPayload(args);');
    }
    for (final p in e.params) {
      w.line('      final ${p.name} = ${codec.read(p.type.name)};');
    }
    final aw = e.isAsync ? 'await ' : '';
    if (e.returnsVoid) {
      w.line('      $aw${e.name}($call);');
      w.line('      return Uint8List(0);');
    } else {
      w.line('      final result = $aw${e.name}($call);');
      w.line('      final w = RecordWriter();');
      w.raw(codec.write(e.returnType.name, 'result', '      '));
      w.line('      return Uint8List.fromList(w.payloadView());');
    }
    w.line('    },');
    w.line('  );');
    w.line('}');
  }
}

/// Name-driven wire codec over the record format. [write] returns statements
/// against writer `w` for value [expr]; [read] returns an expression against
/// reader `r`.
class _EntryCodec {
  _EntryCodec(this.spec)
      : enums = spec.enums.map((x) => x.name).toSet(),
        structs = spec.structs.map((x) => x.name).toSet(),
        records = spec.recordTypes.where((x) => !x.isTuple).map((x) => x.name).toSet(),
        // The analyzer resolves a @NitroTuple typedef to its structural record
        // type, so `(int, String)` must resolve as well as `TcPair`.
        tuples = {
          for (final x in spec.recordTypes.where((x) => x.isTuple)) ...{
            x.name: x,
            '(${x.fields.map((f) => f.dartType).join(', ')})': x,
          },
        },
        variants = spec.variants.map((x) => x.name).toSet();

  final BridgeSpec spec;
  final Set<String> enums, structs, records, variants;
  /// @NitroTuple typedefs have no extension methods (a typedef cannot carry
  /// them), so they are written field by field: `\$1`, `\$2`, ...
  final Map<String, BridgeRecordType> tuples;

  static const _typedData = {'Uint8List', 'Int8List', 'Int16List', 'Uint16List', 'Int32List', 'Uint32List', 'Int64List', 'Uint64List', 'Float32List', 'Float64List'};
  static final _list = RegExp(r'^List<(.+)>$');
  static final _map = RegExp(r'^Map<\s*String\s*,\s*(.+)>$');

  static String _norm(String t) => t.trim().replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'\s*,\s*'), ', ');

  String write(String type, String expr, String indent) {
    final t = _norm(type);
    if (t.endsWith('?')) {
      final inner = t.substring(0, t.length - 1);
      return '${indent}w.writeNullTag($expr == null);\n${indent}if ($expr != null) {\n${write(inner, expr, '$indent  ')}$indent}\n';
    }
    switch (t) {
      case 'int':
        return '${indent}w.writeInt($expr);\n';
      case 'double':
        return '${indent}w.writeDouble($expr);\n';
      case 'bool':
        return '${indent}w.writeBool($expr);\n';
      case 'String':
        return '${indent}w.writeString($expr);\n';
      case 'DateTime':
        return '${indent}w.writeInt($expr.millisecondsSinceEpoch);\n';
      case 'NitroAnyMap':
        return '${indent}w.writeString(jsonEncode($expr.toDynamic()));\n';
    }
    if (_typedData.contains(t)) {
      return '${indent}w.writeBlob(Uint8List.view($expr.buffer, $expr.offsetInBytes, $expr.lengthInBytes));\n';
    }
    if (enums.contains(t)) return '${indent}w.writeInt($expr.nativeValue);\n';
    if (structs.contains(t) || records.contains(t) || variants.contains(t)) return '$indent$expr.writeFields(w);\n';
    final tuple = tuples[t];
    if (tuple != null) {
      final b = StringBuffer();
      for (var i = 0; i < tuple.fields.length; i++) {
        b.write(write(tuple.fields[i].dartType, '$expr.\$${i + 1}', indent));
      }
      return b.toString();
    }
    final l = _list.firstMatch(t);
    if (l != null) {
      final v = '_e${indent.length}';
      return '${indent}w.writeInt32($expr.length);\n${indent}for (final $v in $expr) {\n${write(l.group(1)!, v, '$indent  ')}$indent}\n';
    }
    final m = _map.firstMatch(t);
    if (m != null) {
      final k = '_k${indent.length}';
      final v = '_v${indent.length}';
      return '${indent}w.writeInt32($expr.length);\n$indent$expr.forEach(($k, $v) {\n$indent  w.writeString($k);\n${write(m.group(1)!, v, '$indent  ')}$indent});\n';
    }
    throw StateError('@NitroEntryPoint: no wire codec for type "$t" (SpecValidator should have rejected it)');
  }

  String read(String type) {
    final t = _norm(type);
    if (t.endsWith('?')) return '(r.readNullTag() ? null : ${read(t.substring(0, t.length - 1))})';
    switch (t) {
      case 'int':
        return 'r.readInt()';
      case 'double':
        return 'r.readDouble()';
      case 'bool':
        return 'r.readBool()';
      case 'String':
        return 'r.readString()';
      case 'DateTime':
        return 'DateTime.fromMillisecondsSinceEpoch(r.readInt())';
      case 'NitroAnyMap':
        return 'NitroAnyMap.fromDynamic(jsonDecode(r.readString()) as Map<String, dynamic>)';
    }
    if (t == 'Uint8List') return 'r.readBlob()';
    if (_typedData.contains(t)) return '$t.view(r.readBlob().buffer)';
    if (enums.contains(t)) return 'r.readInt().to$t()';
    if (structs.contains(t) || records.contains(t)) return '${t}RecordExt.fromReader(r)';
    if (variants.contains(t)) return '${t}VariantExt.fromReader(r)';
    final tuple = tuples[t];
    if (tuple != null) return '(${tuple.fields.map((f) => read(f.dartType)).join(', ')})';
    final l = _list.firstMatch(t);
    if (l != null) return 'List<${l.group(1)}>.generate(r.readInt32(), (_) => ${read(l.group(1)!)})';
    final m = _map.firstMatch(t);
    if (m != null) return '<String, ${m.group(1)}>{ for (var i = 0, n = r.readInt32(); i < n; i++) r.readString(): ${read(m.group(1)!)} }';
    throw StateError('@NitroEntryPoint: no wire codec for type "$t" (SpecValidator should have rejected it)');
  }
}
