// Copyright (c) 2026, the Flutter in the Dark project authors.
//
// Unit tests for the v2 grid-fragment format (fitd one-engine grid shell,
// WI-060): per-compile package renaming and the v2 bootstrap/entry
// generation. Pure filesystem asserts — no DDC worker required.

import 'dart:convert';
import 'dart:io';

import 'package:dart_services/src/common.dart';
import 'package:dart_services/src/compiling.dart';
import 'package:dart_services/src/sdk.dart';
import 'package:test/test.dart';

const _fitdSample = '''
// name: grid sample
import 'package:flutter/material.dart';

Widget fitdApp() => const MaterialApp(
      home: Scaffold(body: Center(child: Text('hello grid'))),
    );
''';

const _legacyRunAppSample = '''
// name: legacy sample (v2-missing — compile error must map to main.dart)
import 'package:flutter/material.dart';

void main() {
  runApp(const MaterialApp(home: Scaffold(body: Text('legacy'))));
}
''';

void main() {
  group('v2 grid fragment format', () {
    /// Real end-to-end compiles — require the local SDK corridor
    /// (FLUTTER_ROOT + regenerated artifacts/flutter_web.dill that the
    /// running dartdevc can read, i.e. `grind build-storage-artifacts`).
    late Compiler compiler;
    final sdk = Sdk.fromLocalFlutter();

    setUpAll(() async {
      compiler = Compiler(sdk);
    });

    tearDownAll(() async {
      await compiler.dispose();
    });

    test('compileNewDDCGrid: v2 layout, unique package, stable names', () async {
      final result = await compiler.compileNewDDCGrid(_fitdSample);
      final slug = result.slug!;
      expect(slug, startsWith('fitd_'));
      expect(slug.length, 'fitd_'.length + 12);
      expect(result.entryUri, equals('package:$slug/entry.dart'));
      expect(result.moduleUri, equals('package:$slug/main.dart'));
      final js = result.results.compiledJS!;
      // All three libraries register under the fragment's own package name.
      expect(
          js, contains('dartDevEmbedder.defineLibrary("package:$slug/entry.dart"'));
      expect(
          js, contains('dartDevEmbedder.defineLibrary("package:$slug/boot.dart"'));
      expect(
          js, contains('dartDevEmbedder.defineLibrary("package:$slug/main.dart"'));
      // And the boot registered the factory with the shell bridge (DDC
      // emits double-quoted string constants).
      expect(js, contains('declare'));
      expect(js, contains('fitdApp'));
      // Determinism: same source → same slug (→ same JS bytes → same FNV id).
      final again = await compiler.compileNewDDCGrid(_fitdSample);
      expect(again.slug, slug);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('compileNewDDCGrid: missing fitdApp is a clean main.dart error',
        () async {
      final result = await compiler.compileNewDDCGrid(_legacyRunAppSample);
      expect(result.results.hasOutput, isFalse,
          reason: 'the generated boot references entrypoint.fitdApp which the '
              'runApp-only source does not define');
      final problems = result.results.problems.map((p) => p.message).join('\n');
      expect(problems, contains('fitdApp'));
      expect(problems, startsWith('main.dart'),
          reason: '_rewritePaths maps wrapper-path problems onto main.dart so '
              'the suggestFix loop sees user-file coordinates');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('compileNewDDCGrid: non-flutter source falls back to legacy (no slug)',
        () async {
      const dartSource = 'void main() { print("hi"); }';
      final result = await compiler.compileNewDDCGrid(dartSource);
      expect(result.slug, isNull);
      expect(result.results.hasOutput, isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('v2 grid fragment slug/rename units', () {
    test('slug is deterministic per source and hex-prefixed', () {
      const source = 'import "package:flutter/material.dart";\n'
          'Widget fitdApp() => const SizedBox();\n';
      final a = fnv1aHashHex(source);
      final b = fnv1aHashHex(source);
      expect(a, b);
      expect(a.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
      expect(
          kGridPkgPrefix + a.substring(0, 12),
          startsWith('fitd_'),
          reason: 'slugs are Dart-identifier-safe hex');
    });

    test('slug differs for differing sources', () {
      expect(fnv1aHashHex('a'), isNot(fnv1aHashHex('b')));
    });

    test('boot template: absolute import, no engine boot, registers fn',
        () {
      const slug = 'fitd_abcdef123456';
      final boot = kGridBootDartCode(slug);
      expect(
          boot,
          contains("import 'package:fitd_abcdef123456/main.dart'"),
          reason: 'absolute package import is load-bearing — relative '
              'canonicalization is unreliable in the new-DDC module system');
      expect(boot, isNot(contains('bootstrapEngine')),
          reason: 'v2 fragments never boot an engine');
      expect(boot, isNot(contains('runApp')));
      expect(boot, contains(kGridRegisterFn));
      expect(boot, contains("'declare'"));
      expect(boot, isNot(contains('as JSFunction')),
          reason: 'DDC tear-offs fail the JSFunction cast at runtime — the '
              'shell resolves fitdApp via importLibrary instead');
      expect(boot, contains("'declare'"),
          reason: 'registers the slug with the shell bridge');
    });

    test('entry template: 2-line wrapper with an absolute import', () {
      const slug = 'fitd_abcdef123456';
      final entry = kGridEntryDartCode(slug);
      expect(entry, contains("import 'package:fitd_abcdef123456/boot.dart'"));
      expect(entry, contains('void main() => boot.main();'));
    });

    test('renamePackageForGrid rewrites pubspec + package_config and '
        'self-heals stale SDK paths', () {
      final temp =
          Directory.systemTemp.createTempSync('grid_rename_test');
      try {
        // Minimal fake template in the projected shape.
        final lib = Directory('${temp.path}/lib')..createSync(recursive: true);
        final dartTool =
            Directory('${temp.path}/.dart_tool')..createSync(recursive: true);
        File('${lib.path}/main.dart').writeAsStringSync('// user code\n');
        File('${temp.path}/pubspec.yaml').writeAsStringSync(
            'name: dartpad_sample\nenvironment:\n  sdk: ^3.12.0\n');
        File('${dartTool.path}/package_config.json').writeAsStringSync(
            jsonEncode({
              'configVersion': 2,
              'packages': [
                {
                  'name': 'dartpad_sample',
                  'rootUri': '../',
                  'packageUri': 'lib/',
                  'languageVersion': '3.12'
                },
                {
                  'name': 'flutter',
                  'rootUri': 'file:///nonexistent/sdk/packages/flutter',
                  'packageUri': 'lib/',
                  'languageVersion': '3.12'
                },
              ],
            }));

        const slug = 'fitd_deadbeefcafe';
        final sdkPath = Sdk.fromLocalFlutter().flutterSdkPath;
        renamePackageForGrid(temp.path, slug, sdkPath);

        final pubspec = File('${temp.path}/pubspec.yaml').readAsStringSync();
        expect(pubspec, contains('name: $slug'));
        expect(pubspec, isNot(contains('dartpad_sample')));

        final cfg = jsonDecode(
                File('${dartTool.path}/package_config.json').readAsStringSync())
            as Map<String, dynamic>;
        final names = [
          for (final pkg
              in (cfg['packages'] as List).cast<Map<String, dynamic>>())
            pkg['name'] as String
        ];
        expect(names, contains(slug));
        expect(names, isNot(contains('dartpad_sample')));

        // The stale SDK path got re-pointed at the running SDK.
        final flutter = (cfg['packages'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((p) => p['name'] == 'flutter');
        expect(flutter['rootUri'], equals('file://$sdkPath/packages/flutter'));
      } finally {
        temp.deleteSync(recursive: true);
      }
    });
  });
}
