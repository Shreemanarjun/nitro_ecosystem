// Hybrid isolate (runs on the VM): serves web_assets/ to the browser test
// with permissive CORS, and reports the chosen port over the channel.
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final dir = Directory.current.path;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final name = req.uri.path.split('/').last;
    final file = File('$dir/web_assets/$name');
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    if (!file.existsSync()) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    req.response.headers.contentType = name.endsWith('.wasm')
        ? ContentType('application', 'wasm')
        : ContentType('text', 'javascript');
    await req.response.addStream(file.openRead());
    await req.response.close();
  });
  channel.sink.add(server.port);
  await channel.stream.drain<void>();
}
