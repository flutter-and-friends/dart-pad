// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bazel_worker/driver.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;

import 'analyzer.dart';
import 'common.dart';
import 'logging.dart';
import 'project_templates.dart';
import 'sdk.dart';

final DartPadLogger _logger = DartPadLogger('compiler');

/// FNV-1a 64-bit over UTF-8 bytes, hex-encoded (16 chars). Used for the v2
/// grid fragment slug: deterministic per source, so the same source always
/// compiles to the same package name (and thus the same module names and the
/// same FNV-of-JS compile id — the URL contract stays content-addressed).
///
/// BigInt arithmetic is REQUIRED: Dart ints are signed 64-bit, so a plain
/// `hash * prime` overflows negative and toRadixString(16) would emit a
/// signed string (leading '-' — not a valid Dart identifier and divergent
/// from the fitd tooling's unsigned reference implementation).
String fnv1aHashHex(String input) {
  var hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final prime = BigInt.parse('100000001b3', radix: 16);
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final unit in utf8.encode(input)) {
    hash ^= BigInt.from(unit);
    hash = (hash * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Result of a v2 grid-fragment compile (fitd one-engine grid shell).
class GridCompilation {
  GridCompilation({
    required this.results,
    this.slug,
    required this.entryUri,
    required this.moduleUri,
  });

  final DDCCompilationResults results;

  /// The per-compile package slug (`fitd_<fnv[:12]>`), or null when the
  /// source was served through the LEGACY v1 path (non-Flutter source).
  final String? slug;

  /// `package:<slug>/entry.dart` — the stable `dartDevEmbedder.runMain`
  /// target for this fragment.
  final String entryUri;

  /// `package:<slug>/main.dart` — the user-code module the shell resolves
  /// (informational; the widget factory is registered via `declare`).
  final String moduleUri;
}

/// An interface to the Dart web compilers. A compiler object can process one
/// compile at a time.
class Compiler {
  final Sdk _sdk;
  final BazelWorkerDriver _ddcDriver;

  final ProjectTemplates _projectTemplates;

  Compiler(Sdk sdk) : this._(sdk, path.join(sdk.dartSdkPath, 'bin', 'dart'));

  Compiler._(this._sdk, String dartPath)
    : _ddcDriver = BazelWorkerDriver(
        () => Process.start(dartPath, [
          path.join(
            _sdk.dartSdkPath,
            'bin',
            'snapshots',
            'dartdevc.dart.snapshot',
          ),
          '--persistent_worker',
        ]),
        maxWorkers: 1,
      ),
      _projectTemplates = ProjectTemplates.instance;

  Future<DDCCompilationResults> compileDDC(String source) async {
    return await _compileDDC(source, useNew: false);
  }

  Future<DDCCompilationResults> compileNewDDC(String source) async {
    return await _compileDDC(source, useNew: true);
  }

  /// v2 grid-fragment compile (fitd one-engine grid shell, WI-060).
  ///
  /// Flutter sources compile in the v2 widget-export format: the user source
  /// stays `lib/main.dart` and MUST define a top-level `Widget fitdApp()`; a
  /// generated `lib/boot.dart` registers it with the running grid shell via
  /// `__fitdGrid.declare(slug, fn)` and a 2-line `lib/entry.dart` is the
  /// `runMain` target. The package is renamed per compile to
  /// `fitd_`+FNV-1a(source)[:12] so fragment modules never collide
  /// (ddc_module_loader throws on duplicate library names outside reload)
  /// while staying deterministic per source.
  ///
  /// Non-Flutter Dart sources fall back to the legacy v1 path (no slug —
  /// they cannot participate in the grid).
  Future<GridCompilation> compileNewDDCGrid(String source) async {
    final imports = getAllImportsFor(source);
    if (!usesFlutterWeb(imports)) {
      return GridCompilation(
        results: await _compileDDC(source, useNew: true),
        slug: null,
        entryUri: 'package:$kGridPkgPrefix/entry.dart',
        moduleUri: 'package:$kGridPkgPrefix/main.dart',
      );
    }
    final slug =
        '$kGridPkgPrefix${fnv1aHashHex(source).substring(0, 12)}';
    final results = await _compileDDC(
      source,
      useNew: true,
      gridSlug: slug,
    );
    return GridCompilation(
      results: results,
      slug: slug,
      entryUri: 'package:$slug/entry.dart',
      moduleUri: 'package:$slug/main.dart',
    );
  }

  Future<DDCCompilationResults> compileNewDDCReload(
    String source,
    String deltaDill,
  ) async {
    return await _compileDDC(source, deltaDill: deltaDill, useNew: true);
  }

  /// Compile the given string and return the resulting [DDCCompilationResults].
  ///
  /// [useNew] determines whether or not to use the hot reload enabled module
  /// system for DDC. When [useNew] is true, a null [deltaDill] will result in
  /// a hot restart and a non-null [deltaDill] will result in a hot reload. If
  /// [useNew] is false, the result will always be a hot restart.
  ///
  /// When [gridSlug] is non-null the v2 grid-fragment layout is used instead
  /// of the v1 bootstrap: `lib/main.dart` (user source) + generated
  /// `lib/boot.dart` + `lib/entry.dart`, package renamed to [gridSlug], and
  /// `lib/entry.dart` is the compile entry.
  Future<DDCCompilationResults> _compileDDC(
    String source, {
    String? deltaDill,
    required bool useNew,
    String? gridSlug,
  }) async {
    final imports = getAllImportsFor(source);

    final temp = Directory.systemTemp.createTempSync('dartpad');
    _logger.fine('Temp directory created: ${temp.path}');

    try {
      final usingFlutter = usesFlutterWeb(imports);
      if (usingFlutter) {
        _copyPath(_projectTemplates.flutterPath, temp.path);
      } else {
        _copyPath(_projectTemplates.dartPath, temp.path);
      }

      if (gridSlug != null) {
        assert(deltaDill == null, 'v2 grid fragments do not support reload');
        renamePackageForGrid(temp.path, gridSlug, _sdk.flutterSdkPath);
      }

      Directory(path.join(temp.path, 'lib')).createSync(recursive: true);

      final mainPath = path.join(temp.path, 'lib', kMainDart);
      File(mainPath).writeAsStringSync(source);

      String compilePath;
      if (gridSlug != null) {
        // v2 grid-fragment layout: boot registers the widget, entry is the
        // stable runMain target. Both import main.dart via ABSOLUTE
        // package: URIs (relative-import canonicalization is unreliable in
        // the new-DDC module system).
        File(path.join(temp.path, 'lib', kBootDart))
            .writeAsStringSync(kGridBootDartCode(gridSlug));
        File(path.join(temp.path, 'lib', kEntryDart))
            .writeAsStringSync(kGridEntryDartCode(gridSlug));
        compilePath = path.join(temp.path, 'lib', kEntryDart);
      } else if (useNew && deltaDill != null) {
        // Hot reloads should not recompile the bootstrap library.
        compilePath = mainPath;
      } else {
        // All hot restart (or initial compile) requests should include the
        // bootstrap library.
        final bootstrapPath = path.join(temp.path, 'lib', kBootstrapDart);
        final bootstrapContents = usingFlutter
            ? kBootstrapFlutterCode
            : kBootstrapDartCode;

        File(bootstrapPath).writeAsStringSync(bootstrapContents);
        compilePath = bootstrapPath;
      }
      final newDeltaKernelPath = path.join(temp.path, 'new_kernel.dill');
      String? oldDillPath;
      if (deltaDill != null) {
        final oldDillBytes = base64Decode(deltaDill);
        oldDillPath = path.join(temp.path, 'old_kernel.dill');
        File(oldDillPath)
          ..createSync()
          ..writeAsBytesSync(oldDillBytes);
      }

      final mainJsPath = path.join(temp.path, '$kMainDart.js');

      // Later versions of Flutter remove the "sound" suffix from the file. If
      // the suffixed version does not exist, the unsuffixed version is the
      // sound file.
      var ddcOutlinePath = '${_sdk.flutterWebSdkPath}/ddc_outline_sound.dill';
      if (!File(ddcOutlinePath).existsSync()) {
        ddcOutlinePath = '${_sdk.flutterWebSdkPath}/ddc_outline.dill';
      }

      final arguments = <String>[
        if (useNew) ...[
          '--modules=ddc',
          '--canary',
          '--reload-delta-kernel=$newDeltaKernelPath',
          if (oldDillPath != null) '--reload-last-accepted-kernel=$oldDillPath',
        ],
        if (!useNew) ...['--modules=amd', '--module-name=dartpad_main'],
        '--no-summarize',
        if (usingFlutter) ...[
          '-s',
          _projectTemplates.summaryFilePath,
          '-s',
          ddcOutlinePath,
        ],
        ...['-o', mainJsPath],
        '--enable-asserts',
        if (_sdk.experiments.isNotEmpty)
          '--enable-experiment=${_sdk.experiments.join(",")}',
        compilePath,
        '--packages=${path.join(temp.path, '.dart_tool', 'package_config.json')}',
      ];

      _logger.fine('About to exec dartdevc worker: ${arguments.join(' ')}');

      final response = await _ddcDriver.doWork(
        WorkRequest(arguments: arguments),
      );
      if (response.exitCode != 0) {
        return DDCCompilationResults.failed([
          CompilationProblem._(_rewritePaths(response.output)),
        ]);
      } else {
        final mainJs = File(mainJsPath);
        final newDeltaDill = File(newDeltaKernelPath);

        var compiledJs = mainJs.readAsStringSync();

        if (gridSlug != null) {
          // Corridor tripwire: the generated entry MUST register under its
          // absolute package name — otherwise the shell's runMain target is
          // wrong and the tile would fail to mount at runtime. Relative-
          // import canonicalization glitches (org-dartlang-app names) are
          // the known failure mode when package names disagree.
          const marker = 'dartDevEmbedder.defineLibrary("';
          final expected = '${marker}package:$gridSlug/entry.dart';
          if (!compiledJs.contains(expected)) {
            return const DDCCompilationResults.failed([
              CompilationProblem._(
                'grid compile failed: fragment module names did not '
                'canonicalize (expected package entry name missing). This is '
                'a dart_services template/SDK corridor mismatch, not a user '
                'code error.',
              ),
            ]);
          }
        }

        if (!useNew) {
          // The `--single-out-file` option for dartdevc was removed in v2.7.0. As
          // a result, the JS code produced above does *not* provide a name for
          // the module it contains. That's a problem for DartPad, since it's
          // adding the code to a script tag in an iframe rather than loading it
          // as an individual file from baseURL. As a workaround, this replace
          // statement injects a name into the module definition.
          compiledJs = compiledJs.replaceFirst(
            'define([',
            "define('dartpad_main', [",
          );
        }

        final results = DDCCompilationResults(
          compiledJS: compiledJs,
          deltaDill: useNew
              ? base64Encode(newDeltaDill.readAsBytesSync())
              : null,
        );
        return results;
      }
    } catch (e, st) {
      _logger.warning('Compiler failed: $e\n$st');
      rethrow;
    } finally {
      temp.deleteSync(recursive: true);
      _logger.fine('temp folder removed: ${temp.path}');
    }
  }

  Future<void> dispose() async {
    return _ddcDriver.terminateWorkers();
  }
}

/// The result of a DDC compile.
class DDCCompilationResults {
  final String? compiledJS;
  final String? deltaDill;
  final List<CompilationProblem> problems;

  DDCCompilationResults({this.compiledJS, this.deltaDill})
    : problems = const <CompilationProblem>[];

  const DDCCompilationResults.failed(this.problems)
    : compiledJS = null,
      deltaDill = null;

  bool get hasOutput => compiledJS != null && compiledJS!.isNotEmpty;

  /// This is true if there were no errors.
  bool get success => problems.isEmpty;

  @override
  String toString() => success
      ? 'CompilationResults: Success'
      : 'Compilation errors: ${problems.join('\n')}';
}

/// An issue associated with [DDCCompilationResults].
class CompilationProblem implements Comparable<CompilationProblem> {
  final String message;

  const CompilationProblem._(this.message);

  @override
  int compareTo(CompilationProblem other) => message.compareTo(other.message);

  @override
  String toString() => message;
}

/// Copies all of the files in the [from] directory to [to].
///
/// This is similar to `cp -R <from> <to>`:
/// * Symlinks are supported.
/// * Existing files are over-written, if any.
/// * If [to] is within [from], throws [ArgumentError] (an infinite operation).
/// * If [from] and [to] are canonically the same, no operation occurs.
///
/// Returns a future that completes when complete.
void _copyPath(String from, String to) {
  if (_doNothing(from, to)) {
    return;
  }

  Directory(to).createSync(recursive: true);
  for (final file in Directory(from).listSync(recursive: true)) {
    final copyTo = path.join(to, path.relative(file.path, from: from));
    if (file is Directory) {
      Directory(copyTo).createSync(recursive: true);
    } else if (file is File) {
      File(file.path).copySync(copyTo);
    } else if (file is Link) {
      Link(copyTo).createSync(file.targetSync(), recursive: true);
    }
  }
}

/// Renames the copied template's package to [slug] — pubspec.yaml `name:`
/// AND the matching entry name in `.dart_tool/package_config.json` (they
/// must agree, or the CFE emits `org-dartlang-app:` module names that break
/// the shell's `runMain` target — the spike-provided lesson).
///
/// Self-heal: a checked-in/generated template whose package_config points at
/// an SDK tree that no longer exists (stale checkout) gets its Flutter SDK
/// packages re-pointed at the RUNNING SDK, so v2 compiles work across SDK
/// refreshes without a regrind.
@visibleForTesting
void renamePackageForGrid(
  String templateDir,
  String slug,
  String flutterSdkPath,
) {
  final pubspecFile = File(path.join(templateDir, 'pubspec.yaml'));
  final pubspec = pubspecFile.readAsStringSync();
  if (!pubspec.contains('name: dartpad_sample')) {
    throw StateError(
        'grid template pubspec has unexpected shape (name: dartpad_sample '
        'missing) — template/ground mismatch');
  }
  pubspecFile.writeAsStringSync(
      pubspec.replaceFirst('name: dartpad_sample', 'name: $slug'));

  final cfgPath = path.join(templateDir, '.dart_tool', 'package_config.json');
  final cfg =
      jsonDecode(File(cfgPath).readAsStringSync()) as Map<String, dynamic>;
  final packages =
      (cfg['packages'] as List).cast<Map<String, dynamic>>();
  for (final pkg in packages) {
    if (pkg['name'] == 'dartpad_sample') {
      pkg['name'] = slug;
    }
    final rootUri = pkg['rootUri'] as String? ?? '';
    final dir = _resolveRootUri(templateDir, rootUri);
    if (dir != null &&
        !Directory(dir).existsSync() &&
        const ['flutter', 'flutter_test', 'flutter_web_plugins']
            .contains(pkg['name'])) {
      // Stale SDK path → re-point at the running SDK.
      pkg['rootUri'] = 'file://$flutterSdkPath/packages/${pkg['name']}';
    }
  }
  File(cfgPath)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg));
}

String? _resolveRootUri(String templateDir, String rootUri) {
  if (rootUri.isEmpty) return null;
  final uri = Uri.tryParse(rootUri);
  if (uri == null) return null;
  return uri.isAbsolute
      ? uri.toFilePath()
      : path.normalize(path.join(templateDir, rootUri));
}

bool _doNothing(String from, String to) {
  if (path.canonicalize(from) == path.canonicalize(to)) {
    return true;
  }
  if (path.isWithin(from, to)) {
    throw ArgumentError('Cannot copy from $from to $to');
  }
  return false;
}

/// Remove any references to the bootstrap/entry wrappers and replace with
/// references to 'main.dart', so compile problems surface against the file
/// the user wrote (main.dart) rather than the generated wrapper. v2 adds
/// the boot/entry wrapper names; v1 keeps bootstrap.dart.
String _rewritePaths(String output) {
  final lines = output.split('\n');

  return lines
      .map((line) {
        for (final token in ['lib/bootstrap.dart:', 'lib/boot.dart:',
          'lib/entry.dart:', 'lib/main.dart:']) {
          final index = line.indexOf(token);
          if (index != -1) {
            return 'main.dart:${line.substring(index + token.length)}';
          }
        }
        return line;
      })
      .join('\n');
}
