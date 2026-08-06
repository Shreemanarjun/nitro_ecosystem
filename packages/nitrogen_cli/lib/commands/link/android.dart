part of '../link_command.dart';

// Android linking: Kotlin plugin, JNI load libraries, Gradle/consumer rules.
// Part of the link_command library.

/// Ensures `System.loadLibrary("lib")` is present in the Kotlin plugin's
/// companion object init block for each cpp module lib.
/// cpp modules use `__attribute__((constructor))` for auto-registration, so
/// no JniBridge.register call is needed — just loading the .so is enough.
void linkKotlinLoadLibraries(List<String> libs, {String baseDir = '.'}) {
  final kotlinDir = Directory(
    p.join(baseDir, 'android', 'src', 'main', 'kotlin'),
  );
  if (!kotlinDir.existsSync()) return;
  final pluginFiles = kotlinDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => !f.path.contains('.symlinks'))
      .where((f) => f.path.endsWith('Plugin.kt'))
      .toList();
  if (pluginFiles.isEmpty) return;
  final pluginFile = pluginFiles.first;
  var content = pluginFile.readAsStringSync();
  bool modified = false;
  for (final lib in libs) {
    if (!content.contains('loadLibrary("$lib")')) {
      // Insert after the last existing System.loadLibrary call in the init block
      final match = RegExp(
        r'System\.loadLibrary\("[^"]+"\)',
      ).allMatches(content);
      if (match.isNotEmpty) {
        content = content.replaceFirst(
          match.last.group(0)!,
          '${match.last.group(0)!}\n            System.loadLibrary("$lib")',
        );
      } else {
        // Fallback: inject into existing companion object, or insert a new one.
        final className = p.basenameWithoutExtension(pluginFile.path);
        final classPattern = RegExp('class\\s+$className[^{]*\\{');
        final classMatch = classPattern.firstMatch(content);
        if (classMatch == null) {
          throw Exception(
            'nitrogen link failed: Cannot find opening "{" for class $className in ${p.basename(pluginFile.path)} '
            'to inject System.loadLibrary("$lib"). Please add it manually.',
          );
        }
        // Check if there's already a companion object in the class body
        final classBody = classMatch.group(0)!;
        final companionPattern = RegExp(r'companion\s+object');
        if (companionPattern.hasMatch(content)) {
          // Inject into existing companion object before its closing brace
          final companionMatch = RegExp(
            r'companion\s+object[^{]*\{([^}]*)\}',
          ).firstMatch(content);
          if (companionMatch != null) {
            content = content.replaceFirst(
              companionMatch.group(0)!,
              companionMatch
                  .group(0)!
                  .replaceFirst(
                    '}',
                    '    System.loadLibrary("$lib")\n        }',
                  ),
            );
          } else {
            throw Exception(
              'nitrogen link failed: Found companion object in $className (${p.basename(pluginFile.path)}) '
              'but could not locate its closing brace to inject System.loadLibrary("$lib"). Please add it manually.',
            );
          }
        } else {
          content = content.replaceFirst(
            classBody,
            '$classBody\n    companion object {\n        init { System.loadLibrary("$lib") }\n    }\n',
          );
        }
      }
      modified = true;
    }
  }
  if (modified) pluginFile.writeAsStringSync(content);
}

void linkKotlinPlugin(
  String pluginName,
  List<Map<String, String>> modules, {
  String baseDir = '.',
}) {
  final kotlinDir = Directory(
    p.join(baseDir, 'android', 'src', 'main', 'kotlin'),
  );
  if (!kotlinDir.existsSync()) return;
  final pluginFiles = kotlinDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => !f.path.contains('.symlinks'))
      .where((f) => f.path.endsWith('Plugin.kt'))
      .toList();
  if (pluginFiles.isEmpty) return;
  final pluginFile = pluginFiles.first;
  var content = pluginFile.readAsStringSync();
  bool modified = false;
  for (final m in modules) {
    final name = m['module']!;
    final lib = (m['lib'] ?? name.toLowerCase()).replaceAll('-', '_');
    final reg = '${name}JniBridge';
    final impl = '${name}Impl';
    // The Kotlin generator emits: package nitro.${lib}_module
    // so the fully-qualified import is: import nitro.${lib}_module.${Module}JniBridge
    final importLine = 'import nitro.${lib}_module.$reg';

    // ── 1. Ensure import is present ─────────────────────────────────────────
    if (!content.contains(importLine)) {
      // Insert after the last 'import …' line in the file for clean ordering.
      final importMatches = RegExp(
        r'^import .+$',
        multiLine: true,
      ).allMatches(content);
      if (importMatches.isNotEmpty) {
        final lastImport = importMatches.last;
        content = content.replaceRange(
          lastImport.end,
          lastImport.end,
          '\n$importLine',
        );
      } else {
        // No imports yet — add one blank line after the package declaration.
        content = content.replaceFirstMapped(
          RegExp(r'^package .+$', multiLine: true),
          (m) => '${m.group(0)!}\n\n$importLine',
        );
      }
      modified = true;
    }

    // ── 2. Ensure register() call is present ────────────────────────────────
    // Detect whether XxxImpl needs a Context argument by scanning the impl file.
    // Nitro Kotlin impls commonly take Context in their primary constructor.
    // If we inject XxxImpl() when XxxImpl(context: Context) is required, the
    // call compiles but crashes at runtime — pass binding.applicationContext.
    final implArg = _detectKotlinImplArg(impl, baseDir: baseDir);
    // registerFactory (lambda + Context) — the generated JniBridge's only
    // registration API since the multi-instance registry landed; the old
    // register(impl) overload no longer exists and would not compile.
    final registerCall = '$reg.registerFactory({ $impl($implArg) }, binding.applicationContext)';
    if (!content.contains('$reg.register')) {
      // Anchor after the last existing registration (either legacy
      // register(...) or registerFactory({...}, ctx) — both end-of-line forms).
      final match = RegExp(
        r'\w+JniBridge\.register\w*\(.*\)$',
        multiLine: true,
      ).allMatches(content);
      if (match.isNotEmpty) {
        // Append after the last existing JniBridge.register() call.
        content = content.replaceFirst(
          match.last.group(0)!,
          '${match.last.group(0)!}\n        $registerCall',
        );
      } else {
        content = content.replaceFirst(
          'override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {',
          'override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {\n        $registerCall',
        );
      }
      modified = true;
    }
  }
  if (modified) pluginFile.writeAsStringSync(content);
}

/// Inspects the impl Kotlin file for [implClass] to decide what argument to
/// pass when calling [implClass](...) inside `onAttachedToEngine`.
///
/// Returns `'binding.applicationContext'` if the primary constructor has a
/// `Context` parameter, or `''` (empty — no-arg call) otherwise.
String _detectKotlinImplArg(String implClass, {String baseDir = '.'}) {
  final ktDir = Directory(p.join(baseDir, 'android', 'src', 'main', 'kotlin'));
  if (!ktDir.existsSync()) return '';
  final candidates = ktDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('$implClass.kt')).toList();
  if (candidates.isEmpty) return '';
  final src = candidates.first.readAsStringSync();
  // Match e.g. `class FooImpl(private val context: Context)` or
  //             `class FooImpl(val ctx: Context, ...)`
  if (RegExp(
    r'class\s+' + RegExp.escape(implClass) + r'\s*\([^)]*:\s*Context',
  ).hasMatch(src)) {
    return 'binding.applicationContext';
  }
  return '';
}

/// Removes stale `<Module>JniBridge.register(...)` calls from Plugin.kt for
/// modules that have been converted to NativeImpl.cpp.
///
/// When a user switches `android: NativeImpl.kotlin` → `AndroidNativeImpl.cpp`
/// (or any C++ variant), the old registration call is left as dead code that
/// causes a Kotlin "Unresolved reference" compile error. This function finds
/// and removes those stale calls automatically on every `nitrogen link` run.
void purgeStaleCppKotlinRegistrations(
  List<ModuleInfo> cppModules, {
  String baseDir = '.',
}) {
  if (cppModules.isEmpty) return;
  final kotlinDir = Directory(
    p.join(baseDir, 'android', 'src', 'main', 'kotlin'),
  );
  if (!kotlinDir.existsSync()) return;
  final pluginFiles = kotlinDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => !f.path.contains('.symlinks'))
      .where((f) => f.path.endsWith('Plugin.kt'))
      .toList();
  if (pluginFiles.isEmpty) return;
  final pluginFile = pluginFiles.first;
  var content = pluginFile.readAsStringSync();
  bool modified = false;

  for (final m in cppModules) {
    // Match: <Module>JniBridge.register(<anything>) OR .registerFactory(...)
    // Anchored to line start (^ with multiLine): without it, a module whose
    // class name is a SUFFIX of another's (e.g. cpp module `Present` vs
    // Kotlin module `WebgpuPresent`) would match inside
    // `WebgpuPresentJniBridge.register(...)` and corrupt that line.
    final stalePattern = RegExp(
      r'^[ \t]*' + RegExp.escape('${m.module}JniBridge') + r'\.register\w*\(.*\)[ \t]*\r?\n?',
      multiLine: true,
    );
    if (stalePattern.hasMatch(content)) {
      content = content.replaceAll(stalePattern, '');
      modified = true;
    }
  }

  // Clean up orphaned imports for the removed JniBridge class — ONLY when
  // nothing else in the file still references it. An all-cpp Android module
  // still emits a JniBridge class (lifecycle hooks such as
  // onActivityAttached), and a user's ActivityAware plugin legitimately
  // calls it; removing a still-used import breaks compileDebugKotlin with
  // "Unresolved reference" (issue #16, reopened).
  for (final m in cppModules) {
    // `\.` before the class and a non-identifier boundary after it, so the
    // import of a longer-named sibling (WebgpuPresentJniBridge when purging
    // Present) is never mistaken for this module's import.
    final importPattern = RegExp(
      r'^import [^\n]+?\.' + RegExp.escape('${m.module}JniBridge') + r'(?![A-Za-z0-9_])[^\n]*\n?',
      multiLine: true,
    );
    if (!importPattern.hasMatch(content)) continue;
    final withoutImports = content.replaceAll(importPattern, '');
    // Identifier-boundary usage check: `PresentJniBridge` inside
    // `WebgpuPresentJniBridge` must not count as a remaining usage.
    final usagePattern = RegExp(
      r'(?<![A-Za-z0-9_.])' + RegExp.escape('${m.module}JniBridge') + r'(?![A-Za-z0-9_])',
    );
    if (!usagePattern.hasMatch(withoutImports)) {
      content = withoutImports;
      modified = true;
    }
  }

  if (modified) pluginFile.writeAsStringSync(content);
}

/// Configures `android/build.gradle` (or `.kts`) so the generated Kotlin bridge
/// files in `lib/src/generated/kotlin/` are compiled as part of the Android build.
///
/// Without the `kotlin.srcDirs` entry, all `.bridge.g.kt` files are generated but
/// never compiled — causing "Unresolved reference: XxxJniBridge" errors at build time.
void linkAndroid(
  String pluginName,
  List<String> moduleLibs, {
  String baseDir = '.',
  List<ModuleInfo>? moduleInfos,
}) {
  File? buildGradle;
  for (final candidate in [
    File(p.join(baseDir, 'android', 'build.gradle')),
    File(p.join(baseDir, 'android', 'build.gradle.kts')),
  ]) {
    if (candidate.existsSync()) {
      buildGradle = candidate;
      break;
    }
  }
  if (buildGradle == null) return;

  var content = buildGradle.readAsStringSync();
  bool modified = false;
  final isKts = buildGradle.path.endsWith('.kts');

  // 0. Upgrade a legacy apply-plugin build.gradle to the modern plugins{} DSL.
  final upgrade = _gradleUpgradeToPluginsDsl(content);
  content = upgrade.content;
  modified = modified || upgrade.modified;

  // 1. Ensure kotlin.srcDirs for the generated Kotlin bridges.
  final srcDirs = _gradleEnsureKotlinSrcDirs(content, isKts);
  content = srcDirs.content;
  modified = modified || srcDirs.modified;

  // 2. Ensure kotlinOptions has the expected JVM target for correct bytecode.
  if (!content.contains('kotlinOptions')) {
    final androidMatch = RegExp(r'\bandroid\s*\{').firstMatch(content);
    if (androidMatch != null) {
      content = content.replaceRange(
        androidMatch.end,
        androidMatch.end,
        '\n    kotlinOptions { jvmTarget = "${BuildVersions.androidJvmTarget}" }',
      );
      modified = true;
    }
  }

  // 3. Ensure kotlinx-coroutines (required for generated Kotlin suspend bridge functions).
  if (!content.contains('kotlinx-coroutines')) {
    final depsMatch = RegExp(r'\bdependencies\s*\{').firstMatch(content);
    if (depsMatch != null) {
      content = content.replaceRange(
        depsMatch.end,
        depsMatch.end,
        '\n    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3"\n    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3"',
      );
    } else {
      content +=
          '\ndependencies {\n    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3"\n    implementation "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3"\n}\n';
    }
    modified = true;
  }

  // 4. Ensure consumerProguardFiles "consumer-rules.pro" is wired into
  //    defaultConfig for any module using the Kotlin JNI bridge.
  final proguard = _gradleEnsureConsumerProguard(
    content,
    isKts: isKts,
    moduleInfos: moduleInfos,
    baseDir: baseDir,
  );
  content = proguard.content;
  modified = modified || proguard.modified;

  if (modified) buildGradle.writeAsStringSync(content);
}

/// Upgrades a legacy `apply plugin: "kotlin-android"` android/build.gradle to
/// the modern `plugins {}` DSL: strips the brace-balanced buildscript /
/// rootProject.allprojects blocks and the `apply plugin` lines, inserts a
/// `plugins {}` block at the top (moving group/version below it), and hardcodes
/// ndkVersion. No-op for files already on the plugins DSL.
({String content, bool modified}) _gradleUpgradeToPluginsDsl(String content) {
  var modified = false;
  // 0. Upgrade old-style `apply plugin: "kotlin-android"` to modern plugins{} DSL.
  //    The legacy `buildscript {}` + `apply plugin` approach fails in modern AGP
  //    because `kotlin-android` alias is not resolvable without the classpath in
  //    the consuming app's settings.gradle. Modern Flutter apps use `plugins {}`.
  if (content.contains('apply plugin: "kotlin-android"') || content.contains("apply plugin: 'kotlin-android'")) {
    // Remove the entire buildscript block if present. Must be brace-BALANCED:
    // the old one-nested-block regex left orphan `}` lines behind whenever
    // buildscript contained more than one inner block (repositories +
    // dependencies), corrupting the gradle file ("Unexpected input: '}'").
    content = _removeBraceBalancedBlock(content, RegExp(r'\bbuildscript\s*\{'));
    // Remove rootProject.allprojects block (same brace-balanced treatment —
    // it commonly holds a nested repositories{} block).
    content = _removeBraceBalancedBlock(
      content,
      RegExp(r'\brootProject\.allprojects\s*\{'),
    );
    // Replace apply plugin lines with plugins{} block.
    content = content.replaceAll(
      RegExp(r"apply plugin:\s*'com\.android\.library'\s*\n?"),
      '',
    );
    content = content.replaceAll(
      RegExp(r'apply plugin:\s*"com\.android\.library"\s*\n?'),
      '',
    );
    content = content.replaceAll(
      RegExp(r"apply plugin:\s*'kotlin-android'\s*\n?"),
      '',
    );
    content = content.replaceAll(
      RegExp(r'apply plugin:\s*"kotlin-android"\s*\n?'),
      '',
    );
    // Insert plugins{} block at the very TOP of the file (Gradle requires it
    // before any other statements including group/version assignments).
    if (!content.contains('plugins {') && !content.contains('plugins{')) {
      // Remove group/version from their current position (they'll move after plugins{}).
      final groupVersionMatch = RegExp(
        r'^group\s*=.+\nversion\s*=.+\n',
        multiLine: true,
      ).firstMatch(content);
      String groupVersionBlock = '';
      if (groupVersionMatch != null) {
        groupVersionBlock = groupVersionMatch.group(0)!;
        content = content.replaceFirst(groupVersionBlock, '');
      }
      content =
          'plugins {\n    id "com.android.library"\n    id "org.jetbrains.kotlin.android"\n}\n\n${groupVersionBlock.trim().isEmpty ? "" : "${groupVersionBlock.trim()}\n\n"}${content.trimLeft()}';
    }
    // Fix ndkVersion = android.ndkVersion → hardcoded version for standalone builds.
    content = content.replaceAll(
      'ndkVersion = android.ndkVersion',
      'ndkVersion = "${BuildVersions.androidNdk}"',
    );
    // Collapse sequences of 3+ blank lines to a single blank line (cosmetic cleanup).
    content = content.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    modified = true;
  }
  return (content: content, modified: modified);
}

/// Ensures `kotlin.srcDirs` includes `lib/src/generated/kotlin/` so the
/// generated `.bridge.g.kt` files compile: reuses an existing
/// `sourceSets { main {} }`, adds `main {}` to a bare `sourceSets`, or injects
/// the whole block into `android {}` (creating it if absent). [isKts] selects
/// the Groovy vs Kotlin-DSL srcDirs syntax.
({String content, bool modified}) _gradleEnsureKotlinSrcDirs(
  String content,
  bool isKts,
) {
  var modified = false;
  final srcDirsLine = isKts
      ? r'            kotlin.srcDirs += setOf("${project.projectDir}/../lib/src/generated/kotlin")'
      : r'            kotlin.srcDirs += "${project.projectDir}/../lib/src/generated/kotlin"';

  // 1. Ensure kotlin.srcDirs for generated Kotlin bridges.
  //    .bridge.g.kt files live in lib/src/generated/kotlin/ — Gradle must see
  //    that directory as a Kotlin source root or the JNI bridge classes won't compile.
  //    Note: add to kotlin.srcDirs ONLY, NOT java.srcDirs — in AGP 8.x, routing
  //    .kt through the Java compiler path causes "Unresolved reference: XxxJniBridge".
  if (!content.contains('generated/kotlin')) {
    final sourceSetsMatch = RegExp(r'\bsourceSets\s*\{').firstMatch(content);
    if (sourceSetsMatch != null) {
      // sourceSets block exists — look for main {} inside it.
      final afterSourceSets = content.substring(sourceSetsMatch.end);
      final mainInBlock = RegExp(r'\bmain\s*\{').firstMatch(afterSourceSets);
      if (mainInBlock != null) {
        final mainAbsStart = sourceSetsMatch.end + mainInBlock.start;
        // Find the { of main {} and then its matching }
        final openBrace = content.indexOf(
          '{',
          mainAbsStart + mainInBlock.group(0)!.length - 1,
        );
        if (openBrace >= 0) {
          final mainClose = _findBlockEnd(content, openBrace);
          if (mainClose > 0) {
            content = content.replaceRange(
              mainClose,
              mainClose,
              '\n$srcDirsLine\n        ',
            );
            modified = true;
          }
        }
      } else {
        // sourceSets exists but no main {} — add main {} before sourceSets closing brace
        final sourceSetsClose = _findBlockEnd(content, sourceSetsMatch.end - 1);
        if (sourceSetsClose > 0) {
          content = content.replaceRange(
            sourceSetsClose,
            sourceSetsClose,
            '    main {\n$srcDirsLine\n        }\n    ',
          );
          modified = true;
        }
      }
    } else {
      // No sourceSets block — inject one inside android {}
      final androidMatch = RegExp(r'\bandroid\s*\{').firstMatch(content);
      if (androidMatch != null) {
        content = content.replaceRange(
          androidMatch.end,
          androidMatch.end,
          '\n    sourceSets {\n        main {\n$srcDirsLine\n        }\n    }',
        );
      } else {
        content += '\nandroid {\n    sourceSets {\n        main {\n$srcDirsLine\n        }\n    }\n}\n';
      }
      modified = true;
    }
  }
  return (content: content, modified: modified);
}

/// Wires `consumerProguardFiles "consumer-rules.pro"` into `defaultConfig` for
/// any module using the Kotlin JNI bridge (so linkAndroidConsumerRules's keep
/// rules actually apply to release builds), creating defaultConfig/android {}
/// as needed, and drops an empty placeholder consumer-rules.pro so the
/// reference never points at a missing file.
({String content, bool modified}) _gradleEnsureConsumerProguard(
  String content, {
  required bool isKts,
  List<ModuleInfo>? moduleInfos,
  required String baseDir,
}) {
  var modified = false;
  // 4. Ensure consumerProguardFiles "consumer-rules.pro" is wired into
  //    defaultConfig for any module using the Kotlin JNI bridge — otherwise
  //    linkAndroidConsumerRules's generated keep rules are never actually
  //    applied to a consuming app's release build (silently a no-op).
  final hasKotlinModule = moduleInfos?.any((m) => !m.isAndroidCpp) ?? true;
  if (hasKotlinModule && !content.contains('consumerProguardFiles')) {
    final consumerRulesLine = isKts ? '            consumerProguardFiles("consumer-rules.pro")' : '            consumerProguardFiles "consumer-rules.pro"';
    final defaultConfigMatch = RegExp(r'\bdefaultConfig\s*\{').firstMatch(content);
    if (defaultConfigMatch != null) {
      // Must end with its OWN trailing newline, not just start with one —
      // `defaultConfig { minSdk = 24 }` (a real, valid single-line block) is
      // common in hand-trimmed plugin scaffolds; inserting without a
      // trailing newline here would splice onto whatever follows on that
      // same line (`consumerProguardFiles "..." minSdk = 24 }`), corrupting
      // the file rather than adding a clean, separate statement.
      content = content.replaceRange(
        defaultConfigMatch.end,
        defaultConfigMatch.end,
        '\n$consumerRulesLine\n',
      );
    } else {
      final androidMatch = RegExp(r'\bandroid\s*\{').firstMatch(content);
      final block = '\n    defaultConfig {\n$consumerRulesLine\n    }';
      if (androidMatch != null) {
        content = content.replaceRange(androidMatch.end, androidMatch.end, block);
      } else {
        content += '\nandroid {$block\n}\n';
      }
    }
    modified = true;
    // Safety net: consumerProguardFiles pointing at a missing file is a
    // build error, not a harmless no-op — create an empty placeholder if
    // linkAndroidConsumerRules hasn't run yet (or won't, e.g. call-order
    // dependent). linkAndroidConsumerRules fills in the real content later.
    final rulesFile = File(p.join(baseDir, 'android', 'consumer-rules.pro'));
    if (!rulesFile.existsSync()) rulesFile.writeAsStringSync('');
  }
  return (content: content, modified: modified);
}

/// Marker delimiting the block linkAndroidConsumerRules owns inside
/// `android/consumer-rules.pro` — anything outside it is the plugin author's
/// own rules and is left untouched.
const String _nitroConsumerRulesBeginMarker = '# --- BEGIN nitrogen-generated JNI keep rules (do not edit by hand — regenerated by `nitrogen link`) ---';
const String _nitroConsumerRulesEndMarker = '# --- END nitrogen-generated JNI keep rules ---';

/// Writes/patches `android/consumer-rules.pro` with the R8/ProGuard keep
/// rules every Kotlin-on-Android Nitro module needs.
///
/// The generated JNI bridge (`nitro.<lib>_module.<Module>JniBridge`) and the
/// hand-written impl (under the plugin's Android `namespace`) are reached
/// from C++ via `FindClass` + `GetStaticMethodID` by exact name AND
/// signature — R8 has no static-analysis visibility into that, so without
/// these rules it may rename, remove, or (in "full mode") mis-optimize them.
///
/// Uses `includedescriptorclasses` — not a stronger form of a plain `-keep`,
/// a DIFFERENT protection: plain `-keep class X { *; }` only protects a
/// member from removal/renaming, not the parameter/return TYPES referenced
/// in its signature. For methods JNI calls by exact signature (every
/// `_call` trampoline, several of which take many long/data-class params
/// for suspend methods), an altered parameter type produces a VerifyError
/// at the exact call site — a real, previously-hit crash
/// ("VerifyError ... Long (Low Half)"), not a hypothetical one. This is
/// ProGuard's own documented remedy for native/JNI-called methods.
///
/// Idempotent and additive: only touches the marked block (creating it if
/// absent), never the rest of the file, so a plugin author's own rules for
/// unrelated dependencies survive every `nitrogen link` run. Re-derives the
/// block's content from the CURRENT module list each time, so e.g. adding a
/// second Nitro module to the plugin updates the keep rules automatically.
/// Ensures the plugin's `build.yaml` carries `sources` excludes that keep
/// build_runner's file-discovery walk out of the example app's platform
/// build output (issue #20).
///
/// Once example/ has been built, `example/{ios,macos}/.symlinks/plugins/<name>`
/// symlinks straight back to the plugin root; build_runner follows symlinks
/// with no cycle detection and hangs forever with no output. `nitrogen
/// generate` deletes those dirs before every run — but a plain
/// `dart run build_runner build`/`watch` has no such guard. With the
/// excludes in place the walk never enters example/ at all, making direct
/// build_runner invocations safe too.
///
/// Behavior: creates build.yaml from the template when absent; inserts the
/// `sources:` block under `$default:` when the file exists without one;
/// NEVER touches a file that already declares `sources:` (the user owns
/// their customization — doctor reports if it looks insufficient).
void linkBuildYamlSourcesExcludes({String baseDir = '.'}) {
  final file = File(p.join(baseDir, 'build.yaml'));
  if (!file.existsSync()) {
    file.writeAsStringSync(sft.buildYamlTemplate());
    stdout.writeln('  build.yaml: created with sources excludes (guards direct build_runner runs against the example symlink-cycle hang)');
    return;
  }
  final content = file.readAsStringSync();
  if (content.contains('sources:')) return; // user-owned customization
  const sourcesBlock =
      '    sources:\n'
      '      include:\n'
      '        - lib/**\n'
      '        - \$package\$\n'
      '        - pubspec.yaml\n'
      '      exclude:\n'
      '        - example/**\n'
      '        - "**/.symlinks/**"\n'
      '        - "**/ephemeral/**"\n';
  // Insert directly under the `$default:` target — the shape both the
  // nitrogen template and flutter-created plugins use.
  final anchor = RegExp(r'^(\s*)\$default:\s*$', multiLine: true).firstMatch(content);
  if (anchor == null) {
    stdout.writeln('  build.yaml: unrecognized shape — add sources excludes for example/**, **/.symlinks/**, **/ephemeral/** yourself (see nitrogen doctor)');
    return;
  }
  final insertAt = content.indexOf('\n', anchor.end) + 1;
  final updated = content.substring(0, insertAt) + sourcesBlock + content.substring(insertAt);
  file.writeAsStringSync(updated);
  stdout.writeln('  build.yaml: added sources excludes (guards direct build_runner runs against the example symlink-cycle hang)');
}

/// Removes `pluginClass:` from the plugin pubspec's `windows:`/`linux:`
/// platform entries when that platform is a Nitro C++ (pure-FFI) backend.
///
/// Declaring BOTH `pluginClass` and `ffiPlugin: true` for a desktop platform
/// makes Flutter's tooling classify the plugin as method-channel: the app's
/// generated_plugins.cmake then links a `<plugin>_plugin` CMake target that
/// a pure-FFI plugin never defines —
///   CMake Error: No target `<plugin>_plugin`
/// — blocking every Windows/Linux build of the consuming app (issue #10).
/// The ffiPlugin-only form routes through FLUTTER_FFI_PLUGIN_LIST and the
/// plugin's `<plugin>_bundled_libraries` instead, which is what the
/// generated desktop CMakeLists provide.
///
/// Handles both YAML styles (block children and inline `{ ... }` flow maps),
/// is idempotent, and touches nothing outside the two desktop entries —
/// android/ios/macos keep their pluginClass (those platforms genuinely
/// register a plugin class).
/// Snake-cases a CamelCase plugin class name the way Flutter's tool does when
/// deriving the Linux registrant function (NitroWebgpuPlugin →
/// nitro_webgpu_plugin; consecutive capitals split per letter: CApi → c_api).
String _snakeCasePluginClass(String s) => s.replaceAllMapped(RegExp(r'[A-Z]'), (m) => '_${m.group(0)!.toLowerCase()}').replaceFirst(RegExp(r'^_'), '');

void linkAndroidConsumerRules(
  List<Map<String, String>> kotlinModules, {
  String baseDir = '.',
}) {
  if (kotlinModules.isEmpty) return;
  final androidDir = Directory(p.join(baseDir, 'android'));
  if (!androidDir.existsSync()) return;

  String? namespace;
  for (final candidate in [
    File(p.join(baseDir, 'android', 'build.gradle')),
    File(p.join(baseDir, 'android', 'build.gradle.kts')),
  ]) {
    if (!candidate.existsSync()) continue;
    final m = RegExp(r'''namespace\s*=?\s*["']([^"']+)["']''').firstMatch(candidate.readAsStringSync());
    if (m != null) namespace = m.group(1);
    break;
  }

  final bridgePackages = kotlinModules.map((m) => 'nitro.${(m['lib'] ?? '').replaceAll('-', '_')}_module').toSet().toList()..sort();

  final block = StringBuffer()
    ..writeln(_nitroConsumerRulesBeginMarker)
    ..writeln('# The generated Nitro JNI bridge and its hand-written impl are reached')
    ..writeln('# from C++ via FindClass + GetStaticMethodID by exact name and signature.')
    ..writeln('# includedescriptorclasses additionally keeps the parameter/return types')
    ..writeln('# referenced in those signatures — without it R8 full mode can still')
    ..writeln('# rename/merge them, producing a VerifyError at the JNI call site even')
    ..writeln('# though the method itself is "kept". See linkAndroidConsumerRules in')
    ..writeln('# nitrogen_cli for the full explanation.');
  for (final pkg in bridgePackages) {
    block.writeln('-keep,includedescriptorclasses class $pkg.** {');
    block.writeln('    *;');
    block.writeln('}');
  }
  if (namespace != null) {
    block.writeln('-keep,includedescriptorclasses class $namespace.** {');
    block.writeln('    *;');
    block.writeln('}');
  }
  block
    ..writeln()
    ..writeln('# JNI resolves native methods (Kotlin `external fun`) by exact name AND')
    ..writeln('# signature — includedescriptorclasses protects their parameter/return')
    ..writeln('# types too, not just their names.')
    ..writeln('-keepclasseswithmembernames,includedescriptorclasses class * {')
    ..writeln('    native <methods>;')
    ..writeln('}')
    ..write(_nitroConsumerRulesEndMarker);

  final rulesFile = File(p.join(androidDir.path, 'consumer-rules.pro'));
  final existing = rulesFile.existsSync() ? rulesFile.readAsStringSync() : '';
  final markerPattern = RegExp(
    '${RegExp.escape(_nitroConsumerRulesBeginMarker)}.*?${RegExp.escape(_nitroConsumerRulesEndMarker)}',
    dotAll: true,
  );
  final String updated;
  if (markerPattern.hasMatch(existing)) {
    updated = existing.replaceFirst(markerPattern, block.toString());
  } else if (existing.trim().isEmpty) {
    updated = '$block\n';
  } else {
    updated = '${existing.trimRight()}\n\n$block\n';
  }
  if (updated != existing) rulesFile.writeAsStringSync(updated);
}
