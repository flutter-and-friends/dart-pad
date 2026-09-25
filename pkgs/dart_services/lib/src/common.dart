// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

const kMainDart = 'main.dart';

const kBootstrapDart = 'bootstrap.dart';

const kBootstrapDartCode = r'''
import 'main.dart' as user_code;

void main() {
  user_code.main();
}
''';

// This code should be kept up-to-date with
// https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/web/bootstrap.dart#L236.
const kBootstrapFlutterCode = r'''
import 'dart:ui_web' as ui_web;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

import 'generated_plugin_registrant.dart' as pluginRegistrant;
import 'main.dart' as entrypoint;

@JS('window')
external JSObject get _window;

@JS('reportFlutterError')
external void _reportFlutterError(String message);

Future<void> main() async {
  // Capture errors and throw them to the JS console so DartPad can report them
  // correctly.
  FlutterError.onError = (details) {
    _reportFlutterError(details.toString());
  };

  // Mock DWDS indicators to allow Flutter to register hot reload 'reassemble'
  // extension.
  _window[r'$dwdsVersion'] = true.toJS;
  _window[r'$emitRegisterEvent'] = ((String _) {}).toJS;
  await ui_web.bootstrapEngine(
    runApp: () {
      entrypoint.main();
    },
    registerPlugins: () {
      pluginRegistrant.registerPlugins();
    },
  );
}
''';

/// File names of the v2 "grid fragment" format (fitd one-engine grid shell).
/// The user source stays at `lib/main.dart`; two generated files wrap it.
const kBootDart = 'boot.dart';

const kEntryDart = 'entry.dart';

/// The v2 fragment package prefix. The full slug is `$kGridPkgPrefix<hash>`.
const kGridPkgPrefix = 'fitd_';

/// Per-slug marker the grid shell registry uses.
const kGridRegisterFn = '__fitdGrid';

/// v2 "grid fragment" bootstrap (fitd one-engine grid, WI-060).
///
/// Unlike [kBootstrapFlutterCode] (v1: boots an engine via
/// `bootstrapEngine`), the v2 fragment REGISTERS its root widget with the
/// already-running grid shell and performs NO engine/plugin work — the shell
/// owns the engine. Contract:
///   * user main.dart defines a top-level `Widget fitdApp()` (missing symbol
///     is a COMPILE error on this file, mapped to main.dart by
///     `_rewritePaths` → the suggestFix loop sees a clean signal);
///   * `main()`/`runApp` in the user source is tolerated as dead code;
///   * the import of main.dart is ABSOLUTE (`package:<slug>/main.dart`) —
///     relative-import canonicalization in the new-DDC module system is
///     unreliable (can emit `org-dartlang-app:` names that break the shell's
///     `runMain` target).
/// Parameterized with [slug] — the per-compile package name
/// (`$kGridPkgPrefix<fnv16(source)[:12]>`), which keep fragment modules
/// unique (ddc_module_loader throws on duplicate library names) while
/// staying deterministic (byte-identical recompiles).
String kGridBootDartCode(String slug) => '''
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:$slug/main.dart' as entrypoint;

const String kFitdSlug = '$slug';

@JS('console')
external JSObject get _console;

void main() {
  _console.callMethod('log'.toJS, '[fitd-boot] main entered, slug=$slug'.toJS);
  final grid = globalContext.getProperty('$kGridRegisterFn'.toJS);
  _console.callMethod('log'.toJS,
      ('[fitd-boot] bridge? ' + (grid != null).toString()).toJS);
  if (grid == null) {
    // Not running inside the grid shell (e.g. a plain dartpad embed) — the
    // legacy v1 shell/runner serves fragments instead; say so loudly rather
    // than silently rendering nothing.
    throw StateError(
        '$kGridRegisterFn missing — v2 fragments require the grid shell');
  }
  // Compile-time contract gate: this reference makes a MISSING fitdApp() a
  // compile error on THIS generated file, which _rewritePaths maps onto
  // main.dart — the suggestFix loop's clean signal. Never invoked (the tear
  // -off object is never crossed: DDC closures fail the JSFunction-type
  // interface check at runtime).
  // ignore: unused_local_variable
  final fitdFactoryGate = entrypoint.fitdApp;

  // Register the slug with the shell. The widget FACTORY itself is resolved
  // BY THE SHELL via dartDevEmbedder.importLibrary('package:<slug>/main.dart')
  // and cast to `Widget Function()` there — the importLibrary → Dart-type
  // -cast path is byte-proven by the spike integration run.
  (grid as JSObject).callMethod(
    'declare'.toJS,
    kFitdSlug.toJS,
  );
}
''';

/// v2 fragment entry wrapper — the two-line file whose module name is the
/// stable `dartDevEmbedder.runMain` target for this fragment. Absolute
/// import per the same canonicalization note as the boot template.
String kGridEntryDartCode(String slug) => '''
import 'package:$slug/boot.dart' as boot;

void main() => boot.main();
''';

