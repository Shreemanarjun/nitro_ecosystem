// Release/archive link anchors for CocoaPods (nitro_http #3).
//
// When CocoaPods builds a plugin as a static library, the app's link loads
// only the archive members something references. Nothing references the nitro
// bridges (dlsym) or the C++ impls (static constructor), so a release/archive
// build dropped them: fine in debug, broken from an archive.
//
// `nitrogen link` fixes that with a generated Objective-C translation unit in
// `<platform>/Classes/` that references them; CocoaPods' own `-ObjC` loads it.
// These tests pin the rules that keep that fix from breaking anyone's build:
//   - it never edits the podspec or Package.swift
//   - it references only symbols that are really compiled into the pod
//   - it stays consistent whichever writer (`link` or `watch`) ran last
//   - and, with a real toolchain, the generated files actually survive
//     -dead_strip + strip.
import 'dart:io';

import 'package:nitrogen_cli/commands/link_command.dart';
import 'package:nitrogen_cli/utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// A bridge in the shape nitro_generator emits for an Apple-targeting spec:
// dlsym-only C exports plus the `.desc` keep-block. Self-contained so the
// toolchain test can compile it without the nitro headers.
String _bridge(String lib) =>
    '''
#include <cstdint>
#define NITRO_EXPORT __attribute__((visibility("default"))) __attribute__((used))
struct Hybrid_$lib { virtual int answer() = 0; virtual ~Hybrid_$lib() {} };
static Hybrid_$lib* g_impl_$lib = nullptr;
extern "C" {
void ${lib}_register_impl(Hybrid_$lib* impl) { g_impl_$lib = impl; }
NITRO_EXPORT intptr_t ${lib}_init_dart_api_dl(void* data) { return 0; }
NITRO_EXPORT int32_t ${lib}_answer(void) { return g_impl_$lib ? g_impl_$lib->answer() : -1; }
}

#if defined(__APPLE__)
__asm__(
    ".desc _${lib}_init_dart_api_dl, 0x10\\n"
    ".desc _${lib}_answer, 0x10\\n"
);
#endif
''';

// A user impl in the shape of nitrogen's stub: it registers itself ONLY from a
// static constructor, so nothing references this translation unit.
String _impl(String lib) =>
    '''
struct Hybrid_$lib { virtual int answer() = 0; virtual ~Hybrid_$lib() {} };
extern "C" void ${lib}_register_impl(Hybrid_$lib*);
class Hybrid_${lib}_Impl final : public Hybrid_$lib { public: int answer() override { return 42; } };
static Hybrid_${lib}_Impl g_impl;
__attribute__((constructor))
static void ${lib}_auto_register() { ${lib}_register_impl(&g_impl); }
''';

const _podspec = '''
Pod::Spec.new do |s|
  s.name             = 'my_plugin'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'
end
''';

void main() {
  late Directory root;
  late String classes;
  late String gen;

  File anchors() => File(p.join(classes, 'my_plugin.link_anchors.g.mm'));

  void writeSpec(String lib, {required bool appleCpp}) {
    final cls = lib.split('_').map((w) => w[0].toUpperCase() + w.substring(1)).join();
    final impl = appleCpp ? 'AppleNativeImpl.cpp' : 'NativeImpl.swift';
    File(p.join(root.path, 'lib', 'src', '$lib.native.dart')).writeAsStringSync('''
import 'package:nitro/nitro.dart';
@NitroModule(lib: '$lib', ios: $impl, android: NativeImpl.kotlin, macos: $impl)
abstract class $cls extends HybridObject {}
''');
  }

  void link({bool cppModule = true}) => linkPodspec(
    'my_plugin',
    ['my_plugin'],
    baseDir: root.path,
    moduleInfos: [ModuleInfo(lib: 'my_plugin', module: 'MyPlugin', isCpp: cppModule)],
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('link_anchors_');
    classes = p.join(root.path, 'ios', 'Classes');
    gen = p.join(root.path, 'lib', 'src', 'generated', 'cpp');
    Directory(classes).createSync(recursive: true);
    Directory(gen).createSync(recursive: true);
    Directory(p.join(root.path, 'src')).createSync();
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: my_plugin\nversion: 0.0.1\n');
    File(p.join(root.path, 'ios', 'my_plugin.podspec')).writeAsStringSync(_podspec);

    // A C++-implemented Apple module: bridge + self-registering impl.
    writeSpec('my_plugin', appleCpp: true);
    File(p.join(gen, 'my_plugin.bridge.g.cpp')).writeAsStringSync(_bridge('my_plugin'));
    File(p.join(root.path, 'src', 'HybridMyPlugin.cpp')).writeAsStringSync(_impl('my_plugin'));
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('what gets anchored', () {
    test('a C++ module: its bridge init and its impl translation unit', () {
      link();
      final tu = anchors().readAsStringSync();
      expect(tu, contains('&my_plugin_init_dart_api_dl,'));
      expect(tu, contains('&my_plugin_nitro_link_anchor_HybridMyPlugin,'));
      expect(tu, contains('@implementation NitroLinkAnchors_my_plugin'));

      // The impl forwarder still forwards, and defines the anchor exactly once.
      final fwd = File(p.join(classes, 'HybridMyPlugin.cpp')).readAsStringSync();
      expect(fwd, contains('#include "../../src/HybridMyPlugin.cpp"'));
      expect('void my_plugin_nitro_link_anchor_HybridMyPlugin(void) {}'.allMatches(fwd).length, 1);
      // The user's source is never touched.
      expect(File(p.join(root.path, 'src', 'HybridMyPlugin.cpp')).readAsStringSync(), _impl('my_plugin'));
    });

    test('a Swift-backed module: the bridge only', () {
      writeSpec('my_plugin', appleCpp: false);
      File(p.join(root.path, 'src', 'HybridMyPlugin.cpp')).deleteSync();
      link(cppModule: false);
      final tu = anchors().readAsStringSync();
      expect(tu, contains('&my_plugin_init_dart_api_dl,'));
      expect(tu, isNot(contains('nitro_link_anchor_')));
    });

    test('never a symbol the pod does not define', () {
      // Type-only bridge: no init export at all.
      File(p.join(gen, 'shared_types.bridge.g.cpp')).writeAsStringSync('// shared record types\nstruct Shared {};\n');
      // Bridge from a generator older than 0.8.1: init, but no keep-block.
      File(p.join(gen, 'old_mod.bridge.g.cpp')).writeAsStringSync('extern "C" long old_mod_init_dart_api_dl(void* d) { return 0; }\n');
      // Android-only bridge: init exists, but only under __ANDROID__.
      File(p.join(gen, 'droid_mod.bridge.g.cpp')).writeAsStringSync('#ifdef __ANDROID__\nextern "C" long droid_mod_init_dart_api_dl(void* d) { return 0; }\n#endif\n');
      link();
      final tu = anchors().readAsStringSync();
      for (final absent in ['shared_types', 'old_mod', 'droid_mod']) {
        expect(tu, isNot(contains('${absent}_init_dart_api_dl')), reason: '$absent must not be referenced');
      }
      expect(tu, contains('&my_plugin_init_dart_api_dl,'));
    });

    test('nothing to anchor leaves no file behind', () {
      File(p.join(gen, 'my_plugin.bridge.g.cpp')).writeAsStringSync('// pre-0.8.1 bridge, no keep-block\n');
      File(p.join(root.path, 'src', 'HybridMyPlugin.cpp')).deleteSync();
      writeSpec('my_plugin', appleCpp: false);
      link(cppModule: false);
      expect(anchors().existsSync(), isFalse);
    });
  });

  group('it does not touch build manifests', () {
    test('podspec gains no linker flags and stays valid Ruby', () {
      link();
      final podspec = File(p.join(root.path, 'ios', 'my_plugin.podspec'));
      final text = podspec.readAsStringSync();
      expect(text, isNot(contains('user_target_xcconfig')));
      expect(text, isNot(contains('OTHER_LDFLAGS')));
      expect(text, isNot(contains('-Wl,-u')));
      // nitro's own xcconfig carries \${PODS_ROOT} — a `}` inside the hash.
      expect(text, contains(r'${PODS_ROOT}'));
      if (Process.runSync('which', ['ruby']).exitCode == 0) {
        final r = Process.runSync('ruby', ['-c', podspec.path]);
        expect(r.exitCode, 0, reason: 'podspec is not valid Ruby:\n${r.stderr}');
      }
    });

    test('Package.swift gains no linkerSettings', () {
      link();
      final pkg = File(p.join(root.path, 'ios', 'my_plugin', 'Package.swift'));
      expect(pkg.existsSync(), isTrue);
      expect(pkg.readAsStringSync(), isNot(contains('linkerSettings')));
      expect(pkg.readAsStringSync(), isNot(contains('-Wl,-u')));
    });
  });

  group('it stays consistent', () {
    test('link is idempotent', () {
      link();
      final tu1 = anchors().readAsStringSync();
      final fwd1 = File(p.join(classes, 'HybridMyPlugin.cpp')).readAsStringSync();
      link();
      expect(anchors().readAsStringSync(), tu1);
      expect(File(p.join(classes, 'HybridMyPlugin.cpp')).readAsStringSync(), fwd1);
    });

    test('`watch` (syncBridgeFiles) rewrites the impl as a copy — still anchored', () {
      link();
      final tu = anchors().readAsStringSync();
      syncBridgeFiles(root.path);
      final copy = File(p.join(classes, 'HybridMyPlugin.cpp')).readAsStringSync();
      expect(copy, startsWith(_impl('my_plugin')), reason: 'watch writes a copy of the source');
      expect('void my_plugin_nitro_link_anchor_HybridMyPlugin(void) {}'.allMatches(copy).length, 1);
      expect(anchors().readAsStringSync(), tu, reason: 'the anchors file must match what is on disk');
    });

    test('a removed module is dropped from the anchors', () {
      File(p.join(gen, 'extra.bridge.g.cpp')).writeAsStringSync(_bridge('extra'));
      link();
      expect(anchors().readAsStringSync(), contains('&extra_init_dart_api_dl,'));

      File(p.join(gen, 'extra.bridge.g.cpp')).deleteSync();
      File(p.join(classes, 'extra.bridge.g.mm')).deleteSync();
      link();
      expect(anchors().readAsStringSync(), isNot(contains('extra_init_dart_api_dl')));
    });

    test('an anchors file left by a renamed plugin is removed', () {
      final stale = File(p.join(classes, 'old_name.link_anchors.g.mm'))..writeAsStringSync('// stale');
      link();
      expect(stale.existsSync(), isFalse);
      expect(anchors().existsSync(), isTrue);
    });

    test('a symlinked impl is never written through', () {
      link();
      final outside = File(p.join(root.path, 'vendored.cpp'))..writeAsStringSync('// vendored\n');
      Link(p.join(classes, 'HybridVendored.cpp')).createSync(outside.path);
      writeAppleLinkAnchors(Directory(classes), 'my_plugin');
      expect(outside.readAsStringSync(), '// vendored\n');
      expect(anchors().readAsStringSync(), isNot(contains('HybridVendored')));
    });
  });

  // The real thing: compile exactly what `nitrogen link` put in Classes/ into a
  // static archive, link an app the way CocoaPods does (-ObjC, -dead_strip),
  // strip it like an archive build, and look the bridge up the way Dart does.
  final hasToolchain = Platform.isMacOS && Process.runSync('which', ['clang++']).exitCode == 0;
  group('with a real toolchain', () {
    late String work;

    String run(String exe, List<String> args) {
      final r = Process.runSync(exe, args, workingDirectory: work);
      if (r.exitCode != 0) fail('$exe ${args.join(' ')} failed:\n${r.stdout}\n${r.stderr}');
      return '${r.stdout}';
    }

    String obj(String source) {
      final out = '${p.basenameWithoutExtension(source)}.${source.hashCode.toRadixString(16)}.o';
      run('clang++', ['-std=c++17', '-O2', '-fobjc-arc', '-c', source, '-o', out]);
      return out;
    }

    // Returns what the app prints after linking [objs] as a static archive.
    String appOutput(String tag, List<String> objs) {
      run('libtool', ['-static', '-o', 'lib$tag.a', ...objs]);
      run('clang++', ['main.o', 'lib$tag.a', '-framework', 'Foundation', '-ObjC', '-Wl,-dead_strip', '-o', tag]);
      run('strip', [tag]);
      return run(p.join(work, tag), const []).trim();
    }

    setUp(() {
      work = p.join(root.path, 'build');
      Directory(work).createSync();
      File(p.join(work, 'main.c')).writeAsStringSync('''
#include <dlfcn.h>
#include <stdio.h>
int main(void) {
  void* init = dlsym(RTLD_DEFAULT, "my_plugin_init_dart_api_dl");
  int (*answer)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "my_plugin_answer");
  printf("init=%s answer=%d\\n", init ? "found" : "MISSING", answer ? answer() : -999);
  return 0;
}
''');
      run('clang', ['-c', 'main.c', '-o', 'main.o']);
    });

    test('without the anchors the archive build loses the bridge (the bug)', () {
      link();
      final out = appOutput('before', [obj(p.join(classes, 'my_plugin.bridge.g.mm')), obj(p.join(classes, 'HybridMyPlugin.cpp'))]);
      expect(out, 'init=MISSING answer=-999');
    });

    test('with them the bridge resolves and the C++ impl is registered', () {
      link();
      final out = appOutput('after', [
        obj(p.join(classes, 'my_plugin.bridge.g.mm')),
        obj(p.join(classes, 'HybridMyPlugin.cpp')),
        obj(anchors().path),
      ]);
      expect(out, 'init=found answer=42');
    });

    test('and still does after `watch` swaps the forwarder for a copy', () {
      link();
      syncBridgeFiles(root.path);
      final out = appOutput('watch', [
        obj(p.join(classes, 'my_plugin.bridge.g.mm')),
        obj(p.join(classes, 'HybridMyPlugin.cpp')),
        obj(anchors().path),
      ]);
      expect(out, 'init=found answer=42');
    });

    test('built as a dynamic framework (Flutter\'s default) it simply links', () {
      link();
      final objs = [
        obj(p.join(classes, 'my_plugin.bridge.g.mm')),
        obj(p.join(classes, 'HybridMyPlugin.cpp')),
        obj(anchors().path),
      ];
      run('clang++', ['-dynamiclib', ...objs, '-framework', 'Foundation', '-Wl,-dead_strip', '-o', 'libpod.dylib']);
      run('clang++', ['main.o', '-L.', '-lpod', '-Wl,-dead_strip', '-o', 'dyn']);
      final r = Process.runSync(p.join(work, 'dyn'), const [], workingDirectory: work, environment: {'DYLD_LIBRARY_PATH': work});
      expect('${r.stdout}'.trim(), 'init=found answer=42');
    });
  }, skip: hasToolchain ? false : 'needs macOS + clang++');
}
