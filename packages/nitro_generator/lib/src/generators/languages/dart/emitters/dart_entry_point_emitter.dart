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
  final hasStreams = spec.entryPoints.any((e) => e.isStream);
  final hasCallbacks = spec.entryPoints.any(_EntryCodec.hasCallback);
  _emitBgBindings(w, spec, hasStreams: hasStreams, hasCallbacks: hasCallbacks);
  _emitBgJobHelpers(w, hasCallbacks: hasCallbacks);
  _emitBgRunners(w, hasStreams: hasStreams);
  final codec = _EntryCodec(spec);
  for (final e in spec.entryPoints) {
    w.blankLine();
    _emitRunner(w, e, codec);
    w.blankLine();
    _emitWrapper(w, e, codec);
  }
}

/// FFI bindings of the job table plus the two public probes.
void _emitBgBindings(CodeWriter w, BridgeSpec spec, {required bool hasStreams, required bool hasCallbacks}) {
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
  w.line(
    "final _nitroBgSubmit = _nitroBgDylib.lookupFunction<Int64 Function(Pointer<Utf8>, Pointer<Uint8>, Int64, Int64, Pointer<Int8>), int Function(Pointer<Utf8>, Pointer<Uint8>, int, int, Pointer<Int8>)>('${lib}_bg_submit');",
  );
  w.line("final _nitroBgHasHost = _nitroBgDylib.lookupFunction<Int8 Function(), int Function()>('${lib}_bg_has_host');");
  w.line(
    "final _nitroBgTake = _nitroBgDylib.lookupFunction<Pointer<Uint8> Function(Pointer<Utf8>, Int64, Pointer<Int64>, Pointer<Int64>), Pointer<Uint8> Function(Pointer<Utf8>, int, Pointer<Int64>, Pointer<Int64>)>('${lib}_bg_take_job');",
  );
  w.line("final _nitroBgActiveCount = _nitroBgDylib.lookupFunction<Int64 Function(), int Function()>('${lib}_bg_active_count');");
  w.line("final _nitroBgComplete = _nitroBgDylib.lookupFunction<Int8 Function(Int64, Pointer<Uint8>, Int64), int Function(int, Pointer<Uint8>, int)>('${lib}_bg_complete');");
  w.line("final _nitroBgFail = _nitroBgDylib.lookupFunction<Int8 Function(Int64, Pointer<Utf8>, Pointer<Utf8>), int Function(int, Pointer<Utf8>, Pointer<Utf8>)>('${lib}_bg_fail');");
  w.line("final _nitroBgFree = _nitroBgDylib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('${lib}_nitro_free', isLeaf: true);");
  if (hasCallbacks) {
    w.line("final _nitroBgPost = _nitroBgDylib.lookupFunction<Void Function(Int64, Pointer<Uint8>, Int64), void Function(int, Pointer<Uint8>, int)>('${lib}_bg_post');");
  }
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
}

/// One statement block that copies [blob] into an arena buffer and hands it
/// to [call] as `(buf, len)`.
void _emitArenaCopy(CodeWriter w, String blob, String call) {
  w.line('  final buf = arena<Uint8>($blob.length + 1);');
  w.line('  if ($blob.isNotEmpty) {');
  w.line('    buf.asTypedList($blob.length).setAll(0, $blob);');
  w.line('  }');
  w.line('  $call;');
}

/// take / complete / fail / post / submit — the per-job table calls.
void _emitBgJobHelpers(CodeWriter w, {required bool hasCallbacks}) {
  w.line('({int jobId, Uint8List args})? _nitroBgTakeJob(String entry, int jobId) {');
  w.line('  _nitroBgEnsureApi();');
  w.line('  return using((arena) {');
  w.line('    final idOut = arena<Int64>();');
  w.line('    final lenOut = arena<Int64>();');
  w.line('    final ptr = _nitroBgTake(entry.toNitroUtf8(allocator: arena), jobId, idOut, lenOut);');
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
  _emitArenaCopy(w, 'result', '_nitroBgComplete(jobId, buf, result.length)');
  w.line('});');
  w.blankLine();
  w.line('void _nitroBgFailJob(int jobId, String error, String stackTrace) => using((arena) {');
  w.line('  _nitroBgFail(jobId, error.toNitroUtf8(allocator: arena), stackTrace.toNitroUtf8(allocator: arena));');
  w.line('});');
  w.blankLine();
  if (hasCallbacks) {
    w.line('// Background side of a callback parameter: one blob per call to the');
    w.line("// caller's proxy port.");
    w.line('void _nitroBgPostBlob(int port, Uint8List blob) => using((arena) {');
    _emitArenaCopy(w, 'blob', '_nitroBgPost(port, buf, blob.length)');
    w.line('});');
    w.blankLine();
  }
  w.line('int _nitroBgSubmitJob(String entry, void Function(List<String>) wrapper, Uint8List args, int port) {');
  w.line('  return using((arena) {');
  w.line('    final buf = arena<Uint8>(args.length + 1);');
  w.line('    if (args.isNotEmpty) {');
  w.line('      buf.asTypedList(args.length).setAll(0, args);');
  w.line('    }');
  w.line('    final started = arena<Int8>();');
  w.line('    final id = _nitroBgSubmit(entry.toNitroUtf8(allocator: arena), buf, args.length, port, started);');
  w.line('    // No host engine registered: run the same wrapper on a fresh isolate.');
  w.line('    if (started.value == 0) {');
  w.line('      NitroBackground.spawnFallback(wrapper, id);');
  w.line('    }');
  w.line('    return id;');
  w.line('  });');
  w.line('}');
  w.blankLine();
}

/// The submitter-side generic runners the typed `run<Name>InBackground`
/// functions delegate to.
void _emitBgRunners(CodeWriter w, {required bool hasStreams}) {
  if (hasStreams) {
    w.line('bool _nitroBgEmitItem(int jobId, Uint8List item) => using((arena) {');
    _emitArenaCopy(w, 'item', 'return _nitroBgEmit(jobId, buf, item.length) != 0');
    w.line('});');
    w.blankLine();
    w.line('void _nitroBgEndJob(int jobId) => _nitroBgEnd(jobId);');
    w.blankLine();
    w.line('Stream<R> _nitroBgStream<R>(String entry, void Function(List<String>) wrapper, Uint8List args, R Function(RecordReaderBase r) decode, [List<void Function()> closers = const []]) {');
    w.line('  _nitroBgEnsureApi();');
    w.line('  return NitroBackground.openStream<R>(');
    w.line('    entry: entry,');
    w.line('    submit: (port) => _nitroBgSubmitJob(entry, wrapper, args, port),');
    w.line('    cancel: (jobId) => _nitroBgCancel(jobId),');
    w.line('    decode: (blob) => decode(RecordReaderBase.fromPayload(blob)),');
    w.line('    onClose: () {');
    w.line('      for (final c in closers) {');
    w.line('        c();');
    w.line('      }');
    w.line('    },');
    w.line('  );');
    w.line('}');
    w.blankLine();
  }
  w.line('Future<R> _nitroBgRun<R>(String entry, void Function(List<String>) wrapper, Uint8List args, R Function(RecordReaderBase r) decode, [List<void Function()> closers = const []]) {');
  w.line('  _nitroBgEnsureApi();');
  w.line('  final f = NitroRuntime.openNativeAsync<R>(');
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
  w.line('  if (closers.isNotEmpty) {');
  w.line('    f.whenComplete(() {');
  w.line('      for (final c in closers) {');
  w.line('        c();');
  w.line('      }');
  w.line('    }).ignore();');
  w.line('  }');
  w.line('  return f;');
  w.line('}');
}

/// `Future<T> run<Name>InBackground(...)` / `Stream<T> ...`: encodes the
/// arguments (opening callback proxy ports) and delegates to the runner.
void _emitRunner(CodeWriter w, BridgeEntryPoint e, _EntryCodec codec) {
  final ret = e.returnsVoid ? 'void' : e.returnType.name;
  final cb = _EntryCodec.hasCallback(e);
  final (kind, helper) = e.isStream ? ('Stream', '_nitroBgStream') : ('Future', '_nitroBgRun');
  if (e.isStream) {
    w.line('/// Streams [${e.name}]\'s items from the background — a headless engine on');
    w.line('/// Android/iOS, a spawned isolate elsewhere. Cancelling stops the producer.');
  } else {
    w.line('/// Runs [${e.name}] in the background — a headless engine on Android/iOS,');
    w.line('/// a spawned isolate elsewhere — and returns its result.');
  }
  w.line('$kind<$ret> ${e.runnerName}(${entryPointSignature(e)}) {');
  w.line('  final w = RecordWriter();');
  if (cb) w.line('  final closers = <void Function()>[];');
  for (final p in e.params) {
    w.raw(codec.write(p.type.name, p.name, '  '));
  }
  w.line("  return $helper<$ret>('${e.name}', ${e.wrapperName}, Uint8List.fromList(w.payloadView()), (r) {");
  w.line(e.returnsVoid ? '    return;' : '    return ${codec.read(e.returnType.name)};');
  w.line('  }${cb ? ', closers' : ''});');
  w.line('}');
}

/// The `@pragma('vm:entry-point')` wrapper: takes the job, decodes the
/// arguments, runs the entry and hands the encoded result / items back.
void _emitWrapper(CodeWriter w, BridgeEntryPoint e, _EntryCodec codec) {
  w.line('/// Entry a headless engine (or the fallback isolate) starts at with the');
  w.line('/// job id as its only argument. Keeps [${e.name}] alive under AOT; never');
  w.line('/// call it yourself.');
  w.line("@pragma('vm:entry-point')");
  w.line('void ${e.wrapperName}(List<String> entryArgs) {');
  w.line('  final jobId = NitroBackground.jobIdOf(entryArgs);');
  w.line(e.isStream ? '  NitroBackground.runStreamEntry(' : '  NitroBackground.runEntry(');
  w.line("    entry: '${e.name}',");
  w.line("    takeJob: () => _nitroBgTakeJob('${e.name}', jobId),");
  if (e.isStream) {
    w.line('    emit: _nitroBgEmitItem,');
    w.line('    end: _nitroBgEndJob,');
  } else {
    w.line('    complete: _nitroBgCompleteJob,');
  }
  w.line('    fail: _nitroBgFailJob,');
  w.line(e.isStream ? '    body: (args) {' : '    body: (args) async {');
  if (e.params.isNotEmpty) w.line('      final r = RecordReaderBase.fromPayload(args);');
  for (final p in e.params) {
    w.line('      final ${p.name} = ${codec.read(p.type.name)};');
  }
  _emitWrapperResult(w, e, codec);
  w.line('    },');
  w.line('  );');
  w.line('}');
}

void _emitWrapperResult(CodeWriter w, BridgeEntryPoint e, _EntryCodec codec) {
  final call = '${e.name}(${entryPointCallArgs(e)})';
  if (e.isStream) {
    w.line('      return $call.map((item) {');
    w.line('        final w = RecordWriter();');
    w.raw(codec.write(e.returnType.name, 'item', '        '));
    w.line('        return Uint8List.fromList(w.payloadView());');
    w.line('      });');
    return;
  }
  final aw = e.isAsync ? 'await ' : '';
  if (e.returnsVoid) {
    w.line('      $aw$call;');
    w.line('      return Uint8List(0);');
    return;
  }
  w.line('      final result = $aw$call;');
  w.line('      final w = RecordWriter();');
  w.raw(codec.write(e.returnType.name, 'result', '      '));
  w.line('      return Uint8List.fromList(w.payloadView());');
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
  int _callbackSeq = 0;

  static const _typedData = {'Uint8List', 'Int8List', 'Int16List', 'Uint16List', 'Int32List', 'Uint32List', 'Int64List', 'Uint64List', 'Float32List', 'Float64List'};
  static final _list = RegExp(r'^List<(.+)>$');
  static final _map = RegExp(r'^Map<\s*(\w+)\s*,\s*(.+)>$');
  static final _handle = RegExp(r'^NativeHandle<(.+)>$');
  static final _pointer = RegExp(r'^Pointer<(.+)>$');
  static final _callback = RegExp(r'^void Function\((.*)\)$');

  /// Any parameter (also nested in a list/map/nullable) that is a callback:
  /// the runner then owns proxy ports it must close when the job is over.
  static bool hasCallback(BridgeEntryPoint e) => e.params.any((p) => p.type.name.contains(' Function('));

  static String _norm(String t) => t.trim().replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'\s*,\s*'), ', ');

  /// `int a` → `int`; the analyzer may or may not print positional names.
  static String _paramType(String seg) => RegExp(r'^(.*\S)\s+(\w+)$').firstMatch(seg)?.group(1) ?? seg;

  static List<String> _callbackParams(String t) => splitTopLevelTypeArgs(_callback.firstMatch(t)!.group(1)!).map(_paramType).toList();

  String _codecOf(String t) => 'const ${spec.customTypeByName(t)!.codecClass}()';

  String write(String type, String expr, String indent) {
    final t = _norm(type);
    return switch (t) {
      _ when t.endsWith('?') => '${indent}w.writeNullTag($expr == null);\n${indent}if ($expr != null) {\n${write(t.substring(0, t.length - 1), expr, '$indent  ')}$indent}\n',
      'int' => '${indent}w.writeInt($expr);\n',
      'double' => '${indent}w.writeDouble($expr);\n',
      'bool' => '${indent}w.writeBool($expr);\n',
      'String' => '${indent}w.writeString($expr);\n',
      'DateTime' => '${indent}w.writeInt($expr.millisecondsSinceEpoch);\n',
      'NitroAnyMap' => '$indent$expr.writeTo(w);\n',
      'AnyNativeObject' => '${indent}w.writeInt($expr.instanceId);\n',
      _ when _typedData.contains(t) => '${indent}w.writeBlob(Uint8List.view($expr.buffer, $expr.offsetInBytes, $expr.lengthInBytes));\n',
      _ when enums.contains(t) => '${indent}w.writeInt($expr.nativeValue);\n',
      _ when structs.contains(t) || records.contains(t) || variants.contains(t) => '$indent$expr.writeFields(w);\n',
      // Same process on both sides: handles and pointers cross by address, the
      // caller keeps ownership.
      _ when _handle.hasMatch(t) || _pointer.hasMatch(t) => '${indent}w.writeInt($expr.address);\n',
      _ when spec.isCustomTypeName(t) => '${indent}w.writeBlob(using((a) => Uint8List.fromList(${_codecOf(t)}.encode($expr, a).asTypedList(${_codecOf(t)}.encodedSize))));\n',
      _ when _callback.hasMatch(t) => _writeCallback(t, expr, indent),
      _ when tuples.containsKey(t) => [for (final (i, f) in tuples[t]!.fields.indexed) write(f.dartType, '$expr.\$${i + 1}', indent)].join(),
      _ when _list.hasMatch(t) => _writeList(_list.firstMatch(t)!.group(1)!, expr, indent),
      _ when _map.hasMatch(t) => _writeMap(_map.firstMatch(t)!, expr, indent),
      _ => throw StateError('@NitroEntryPoint: no wire codec for type "$t" (SpecValidator should have rejected it)'),
    };
  }

  /// Caller side of a callback: a proxy port; each posted blob is one call's
  /// arguments, decoded here and handed to the real callback.
  String _writeCallback(String t, String expr, String indent) {
    final n = _callbackSeq++;
    final params = _callbackParams(t);
    final b = StringBuffer()..write('${indent}final (_port$n, _close$n) = NitroBackground.callbackPort((blob) {\n');
    if (params.isNotEmpty) b.write('$indent  final r = RecordReaderBase.fromPayload(blob);\n');
    b
      ..write('$indent  $expr(${params.map(read).join(', ')});\n')
      ..write('$indent});\n')
      ..write('${indent}closers.add(_close$n);\n')
      ..write('${indent}w.writeInt(_port$n);\n');
    return b.toString();
  }

  String _writeList(String item, String expr, String indent) {
    final v = '_e${indent.length}';
    return '${indent}w.writeInt32($expr.length);\n${indent}for (final $v in $expr) {\n${write(item, v, '$indent  ')}$indent}\n';
  }

  String _writeMap(RegExpMatch m, String expr, String indent) {
    final k = '_k${indent.length}';
    final v = '_v${indent.length}';
    return '${indent}w.writeInt32($expr.length);\n$indent$expr.forEach(($k, $v) {\n$indent  ${_writeKey(m.group(1)!, k)};\n${write(m.group(2)!, v, '$indent  ')}$indent});\n';
  }

  String _writeKey(String keyType, String expr) => switch (keyType) {
    'String' => 'w.writeString($expr)',
    'int' => 'w.writeInt($expr)',
    _ when enums.contains(keyType) => 'w.writeInt($expr.nativeValue)',
    _ => throw StateError('@NitroEntryPoint: unsupported map key type "$keyType"'),
  };

  String _readKey(String keyType) => switch (keyType) {
    'String' => 'r.readString()',
    'int' => 'r.readInt()',
    _ when enums.contains(keyType) => 'r.readInt().to$keyType()',
    _ => throw StateError('@NitroEntryPoint: unsupported map key type "$keyType"'),
  };

  String read(String type) {
    final t = _norm(type);
    return switch (t) {
      _ when t.endsWith('?') => '(r.readNullTag() ? null : ${read(t.substring(0, t.length - 1))})',
      'int' => 'r.readInt()',
      'double' => 'r.readDouble()',
      'bool' => 'r.readBool()',
      'String' => 'r.readString()',
      'DateTime' => 'DateTime.fromMillisecondsSinceEpoch(r.readInt())',
      'NitroAnyMap' => 'NitroAnyMap.readFrom(r)',
      'AnyNativeObject' => 'AnyNativeObject(r.readInt())',
      'Uint8List' => 'r.readBlob()',
      _ when _typedData.contains(t) => '$t.view(r.readBlob().buffer)',
      _ when enums.contains(t) => 'r.readInt().to$t()',
      _ when structs.contains(t) || records.contains(t) => '${t}RecordExt.fromReader(r)',
      _ when variants.contains(t) => '${t}VariantExt.fromReader(r)',
      _ when _handle.hasMatch(t) => 'NativeHandle<${_handle.firstMatch(t)!.group(1)}>.fromAddress(r.readInt())',
      _ when _pointer.hasMatch(t) => 'Pointer<${_pointer.firstMatch(t)!.group(1)}>.fromAddress(r.readInt())',
      _ when spec.isCustomTypeName(t) => 'using((a) { final b = r.readBlob(); final p = a<Uint8>(b.length); p.asTypedList(b.length).setAll(0, b); return ${_codecOf(t)}.decode(p)!; })',
      _ when _callback.hasMatch(t) => _readCallback(t),
      _ when tuples.containsKey(t) => '(${tuples[t]!.fields.map((f) => read(f.dartType)).join(', ')})',
      _ when _list.hasMatch(t) => 'List<${_list.firstMatch(t)!.group(1)}>.generate(r.readInt32(), (_) => ${read(_list.firstMatch(t)!.group(1)!)})',
      _ when _map.hasMatch(t) => _readMap(_map.firstMatch(t)!),
      _ => throw StateError('@NitroEntryPoint: no wire codec for type "$t" (SpecValidator should have rejected it)'),
    };
  }

  /// Background side of a callback: a closure that posts its arguments to the
  /// proxy port read from the blob right here (the IIFE keeps the read in
  /// sequence with the other arguments).
  String _readCallback(String t) {
    final params = _callbackParams(t);
    final sig = [for (final (i, p) in params.indexed) '$p a$i'].join(', ');
    final body = [for (final (i, p) in params.indexed) write(p, 'a$i', '')].join();
    return '(() { final port = r.readInt(); return ($sig) { final w = RecordWriter(); $body _nitroBgPostBlob(port, Uint8List.fromList(w.payloadView())); }; })()';
  }

  String _readMap(RegExpMatch m) => '<${m.group(1)}, ${m.group(2)}>{ for (var i = 0, n = r.readInt32(); i < n; i++) ${_readKey(m.group(1)!)}: ${read(m.group(2)!)} }';
}
