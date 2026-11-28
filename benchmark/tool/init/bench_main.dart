import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:nitro/nitro.dart';
import 'package:nitro_init_bench/nitro_init_bench.dart';

// Cold-start benchmark of Nitro module initialization. Every launch is a fresh
// process; the collector on the host says which mode to run and which module
// goes first (rotated), and receives the numbers.
final _host = Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';

class _Mod {
  final String name, lib;
  final List<String> methods;
  final Object Function() instance;
  final int Function() ping;
  final Object Function() point;
  final Future<int> Function() pingAsync;
  _Mod(this.name, this.lib, this.methods, this.instance, this.ping, this.point, this.pingAsync);
}

final _mods = [
  _Mod('swift', 'ib_swift', ['ping', 'point', 'ping_async_dispatch'], () => IbSwift.instance, () => IbSwift.instance.ping(1), () => IbSwift.instance.point(), () => IbSwift.instance.pingAsync(1)),
  _Mod('cpp', 'ib_cpp', ['ping', 'point', 'ping_async_dispatch'], () => IbCpp.instance, () => IbCpp.instance.ping(1), () => IbCpp.instance.point(), () => IbCpp.instance.pingAsync(1)),
  _Mod('mixed', 'ib_mixed', ['ping', 'point', 'ping_async_dispatch'], () => IbMixed.instance, () => IbMixed.instance.ping(1), () => IbMixed.instance.point(), () => IbMixed.instance.pingAsync(1)),
  _Mod('wide', 'ib_wide', ['ping', 'point', 'ping_async_dispatch', for (var i = 0; i < 64; i++) 'm$i'], () => IbWide.instance, () => IbWide.instance.ping(1), () => IbWide.instance.point(), () => IbWide.instance.pingAsync(1)),
];

const _common = ['nitro_free', 'nitro_alloc', 'nitro_ack', 'nitro_bind', 'nitro_arm', 'nitro_disarm', 'nitro_poll', 'get_error', 'clear_error', 'destroy_instance'];

double _us(Stopwatch s) => s.elapsedTicks * 1e6 / s.frequency;

Map<String, Object> _plain(_Mod m) {
  final r = <String, Object>{};
  var s = Stopwatch()..start();
  m.instance();
  r['ctor_us'] = _us(s);
  s = Stopwatch()..start();
  m.ping();
  r['sync1_us'] = _us(s);
  s = Stopwatch()..start();
  m.point();
  r['struct1_us'] = _us(s);
  s = Stopwatch()..start();
  for (var i = 0; i < 20000; i++) {
    m.ping();
  }
  r['sync_warm_ns'] = _us(s) * 1000 / 20000;
  return r;
}

Future<Map<String, Object>> _async(_Mod m) async {
  final s = Stopwatch()..start();
  await m.pingAsync();
  final first = _us(s);
  final w = Stopwatch()..start();
  for (var i = 0; i < 500; i++) {
    await m.pingAsync();
  }
  return {'async1_us': first, 'async_warm_us': _us(w) / 500};
}

// The constructor's steps one by one against the raw library.
Map<String, Object> _breakdown(_Mod m) {
  final r = <String, Object>{};
  final l = m.lib;
  var s = Stopwatch()..start();
  final lib = Platform.isAndroid ? DynamicLibrary.open('lib$l.so') : DynamicLibrary.process();
  r['open_us'] = _us(s);
  s = Stopwatch()..start();
  for (final sym in ['nitro_abi_version', 'nitro_bridge_checksum']) {
    lib.providesSymbol('${l}_$sym');
  }
  r['provides2_us'] = _us(s);
  s = Stopwatch()..start();
  final initCode = lib.lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>('${l}_init_dart_api_dl')(NativeApi.initializeApiDLData);
  r['init_dl_us'] = _us(s);
  s = Stopwatch()..start();
  lib.lookupFunction<Uint32 Function(), int Function()>('${l}_nitro_abi_version')();
  r['abi_us'] = _us(s);
  s = Stopwatch()..start();
  lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('${l}_nitro_bridge_checksum')().toDartString();
  r['checksum_us'] = _us(s);
  s = Stopwatch()..start();
  final create = lib.lookupFunction<Int64 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>('${l}_create_instance');
  r['lookup_create_us'] = _us(s);
  final key = 'bench'.toNativeUtf8();
  s = Stopwatch()..start();
  final id = create(key);
  r['create_call_us'] = _us(s);
  malloc.free(key);
  final syms = [..._common, ...m.methods];
  s = Stopwatch()..start();
  for (final sym in syms) {
    lib.lookup<Void>('${l}_$sym');
  }
  r['lookup_all_us'] = _us(s);
  r['lookup_all_n'] = syms.length;
  r['ok'] = initCode == 0 && id >= 0;
  return r;
}

Future<void> _run() async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse('http://$_host:8765/next'));
    final cfg = jsonDecode(await (await req.close()).transform(utf8.decoder).join()) as Map<String, dynamic>;
    final mode = cfg['mode'] as String;
    final rot = cfg['rot'] as int;
    final order = [for (var i = 0; i < _mods.length; i++) _mods[(i + rot) % _mods.length]];
    final out = <String, Object>{'mode': mode, 'platform': Platform.operatingSystem, 'first': order.first.name};
    for (final m in order) {
      if (mode == 'breakdown') {
        out[m.name] = _breakdown(m);
      } else {
        out[m.name] = {..._plain(m), ...await _async(m)};
      }
    }
    final body = utf8.encode(jsonEncode(out));
    final post = await c.postUrl(Uri.parse('http://$_host:8765/result'))..contentLength = body.length;
    post.add(body);
    await (await post.close()).drain<void>();
  } finally {
    c.close();
    exit(0);
  }
}

void main() {
  NitroConfig.instance.logLevel = NitroLogLevel.none;
  runApp(const Directionality(textDirection: TextDirection.ltr, child: Center(child: Text('bench'))));
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
}
