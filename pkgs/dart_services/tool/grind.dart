// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// ignore_for_file: unreachable_from_main

import 'dart:async';
import 'dart:convert' show JsonEncoder, jsonDecode;
import 'dart:io';

import 'package:dart_services/src/project_creator.dart';
import 'package:dart_services/src/project_templates.dart';
import 'package:dart_services/src/pub.dart';
import 'package:dart_services/src/sdk.dart';
import 'package:dart_services/src/utils.dart';
import 'package:grinder/grinder.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as path;

Future<void> main(List<String> args) async {
  return grind(args);
}

final List<String> compilationArtifacts = ['dart_sdk.js', 'flutter_web.js'];

final List<String> compilationArtifactsNew = [
  'dart_sdk_new.js',
  'flutter_web_new.js',
  'ddc_module_loader.js',
];

/// Builds the two project templates:
///
/// * the Dart project template
/// * the Flutter project template
@Task('Build the project templates')
void buildProjectTemplates() async {
  final templatesPath = path.join(Directory.current.path, 'project_templates');
  final templatesDirectory = Directory(templatesPath);
  if (await templatesDirectory.exists()) {
    log('Removing ${templatesDirectory.path}');
    await templatesDirectory.delete(recursive: true);
  }

  final sdk = Sdk.fromLocalFlutter();
  final projectCreator = ProjectCreator(
    sdk,
    templatesPath,
    dartLanguageVersion: sdk.dartVersion,
    dependenciesFile: _pubDependenciesFile(channel: sdk.channel),
    log: log,
  );
  await projectCreator.buildDartProjectTemplate();
  await projectCreator.buildFlutterProjectTemplate();
}

@DefaultTask('Build the sdk compilation artifacts')
void buildStorageArtifacts() async {
  final sdk = Sdk.fromLocalFlutter();
  delete(getDir('artifacts'));

  // Build and copy ddc_module_loader.js, dart_sdk.js, flutter_web.js, and
  // flutter_web.dill.
  final temp = Directory.systemTemp.createTempSync('flutter_web_sample');

  try {
    await _buildStorageArtifacts(temp, sdk, channel: sdk.channel);
  } finally {
    temp.deleteSync(recursive: true);
  }
}

// Packages to include in flutter_web.js. These are implicitly imported by all
// flutter apps. Since DDC doesn't do tree-shaking these would be included in
// every compilation.
const _flutterPackages = {
  'flutter',
  'flutter_test',
  'url_launcher_web',
  'shared_preferences_web',
  'video_player_web',
  'shared_preferences_platform_interface',
  'video_player_platform_interface',
  'web',
};

Future<void> _buildStorageArtifacts(
  Directory dir,
  Sdk sdk, {
  required String channel,
}) async {
  final dependenciesFile = _pubDependenciesFile(channel: channel);
  final pubspec = createPubspec(
    includeFlutterWeb: true,
    dartLanguageVersion: sdk.dartVersion,
    dependencies: parsePubDependenciesFile(dependenciesFile: dependenciesFile),
  );
  joinFile(dir, ['pubspec.yaml']).writeAsStringSync(pubspec);

  // Make sure the tooling knows this is a Flutter Web project
  final indexHtmlFile = File(path.join(dir.path, 'web', 'index.html'))
    ..parent.createSync();
  indexHtmlFile.writeAsStringSync('''
<!DOCTYPE html>
<html>
<head>
  <base href="/">

  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">

  <script src="main.dart.js" defer></script>
</head>

<body>
</body>
</html>
''');

  await runFlutterPubGet(sdk, dir.path, log: log);

  // Working around Flutter 3.3's deprecation of generated_plugin_registrant.dart
  // Context: https://github.com/flutter/flutter/pull/106921

  final pluginRegistrant = File(
    path.join(dir.path, '.dart_tool', 'dartpad', 'web_plugin_registrant.dart'),
  );
  if (pluginRegistrant.existsSync()) {
    Directory(path.join(dir.path, 'lib')).createSync();
    pluginRegistrant.copySync(
      path.join(dir.path, 'lib', 'generated_plugin_registrant.dart'),
    );
  }

  final flutterLibraries = <String>[];
  final config = await findPackageConfig(dir);
  if (config == null) {
    throw FileSystemException('package config not found', dir.toString());
  }
  for (final package in config.packages) {
    if (_flutterPackages.contains(package.name)) {
      // This is a package we're interested in - add all the public libraries to
      // the list.
      final libPath = package.packageUriRoot.toFilePath();
      for (final entity in getDir(libPath).listSync()) {
        if (entity is File && entity.path.endsWith('.dart')) {
          flutterLibraries.add('package:${package.name}/${fileName(entity)}');
        }
      }
    }
  }

  // Make sure
  // <flutter-sdk>/bin/cache/flutter_web_sdk/kernel/ddc_outline.dill is
  // installed.
  await _run(
    sdk.flutterToolPath,
    arguments: ['precache', '--web'],
    workingDirectory: dir.path,
  );

  // Build the artifacts using DDC:
  // dart-sdk/bin/dartdevc -s kernel/ddc_outline.dill
  //     --modules=amd package:flutter/animation.dart ...
  final compilerPath = path.join(sdk.dartSdkPath, 'bin', 'dart');

  // Later versions of Flutter remove the "sound" suffix from files. If the
  // suffixed version does not exist, the unsuffixed version is the sound file.
  var dillPath = path.join(sdk.flutterWebSdkPath, 'ddc_outline_sound.dill');
  var sdkJsPath = path.join(
    sdk.flutterWebSdkPath,
    'amd-canvaskit-sound/dart_sdk.js',
  );
  if (!getFile(dillPath).existsSync()) {
    dillPath = path.join(sdk.flutterWebSdkPath, 'ddc_outline.dill');
    sdkJsPath = path.join(sdk.flutterWebSdkPath, 'amd-canvaskit/dart_sdk.js');
  }

  final arguments = <String>[
    path.join(sdk.dartSdkPath, 'bin', 'snapshots', 'dartdevc.dart.snapshot'),
    '-s',
    dillPath,
    '--modules=amd',
    '--source-map',
    '-o',
    'flutter_web.js',
    ...flutterLibraries,
  ];

  await _run(compilerPath, arguments: arguments, workingDirectory: dir.path);

  // Copy all to the project directory.
  final artifactsDir = getDir(path.join('artifacts'));
  artifactsDir.createSync(recursive: true);

  copy(getFile(sdkJsPath), artifactsDir);
  copy(getFile('$sdkJsPath.map'), artifactsDir);
  copy(joinFile(dir, ['flutter_web.js']), artifactsDir);
  copy(joinFile(dir, ['flutter_web.js.map']), artifactsDir);
  copy(joinFile(dir, ['flutter_web.dill']), artifactsDir);

  // We only expect these hot reload artifacts to work at version 3.8 and later.
  if (sdk.useNewDdcSdk) {
    // Later versions of Flutter remove the "sound" suffix from the file. If
    // the suffixed version does not exist, the unsuffixed version is the sound
    // file.
    var newSdkJsPath = path.join(
      sdk.flutterWebSdkPath,
      'ddcLibraryBundle-canvaskit-sound/dart_sdk.js',
    );
    if (!getFile(newSdkJsPath).existsSync()) {
      newSdkJsPath = path.join(
        sdk.flutterWebSdkPath,
        'ddcLibraryBundle-canvaskit/dart_sdk.js',
      );
    }
    final ddcModuleLoaderPath = path.join(
      sdk.dartSdkPath,
      'lib/dev_compiler/ddc/ddc_module_loader.js',
    );

    final argumentsNew = <String>[
      path.join(sdk.dartSdkPath, 'bin', 'snapshots', 'dartdevc.dart.snapshot'),
      '-s',
      dillPath,
      '--modules=ddc',
      '--canary',
      '--source-map',
      // The dill file will be the same between legacy and new compilation.
      '--no-summarize',
      '-o',
      'flutter_web_new.js',
      ...flutterLibraries,
    ];

    await _run(
      compilerPath,
      arguments: argumentsNew,
      workingDirectory: dir.path,
    );

    copy(getFile(ddcModuleLoaderPath), artifactsDir);
    copy(getFile(newSdkJsPath), artifactsDir);
    copy(getFile('$newSdkJsPath.map'), artifactsDir);
    joinFile(artifactsDir, [
      'dart_sdk.js',
    ]).copySync(path.join('artifacts', 'dart_sdk_new.js'));
    joinFile(artifactsDir, [
      'dart_sdk.js.map',
    ]).copySync(path.join('artifacts', 'dart_sdk_new.js.map'));

    copy(joinFile(dir, ['flutter_web_new.js']), artifactsDir);
    copy(joinFile(dir, ['flutter_web_new.js.map']), artifactsDir);

    // Static runtime assets the compiled-app shell (compile_serve.dart
    // `_shellHtml`) loads from /artifacts/: require.js + flutter.js in
    // <script> tags, and canvaskit/ via canvasKitBaseUrl. Without these the
    // deployed backend 404s them and every compiled iframe dies with
    // "require is not defined".

    // require.js: use the copy vendored in dartpad_ui/web — it is the loader
    // dartpad_ui's frame.html pairs with ddc_module_loader for the new-DDC
    // (library bundle) bootstrap, which is exactly the combination the shell
    // uses. (The Dart SDK ships a different, much larger require.js under
    // lib/dev_compiler/amd/ for the legacy AMD pipeline.)
    copy(
      getFile(
        path.join(
          Directory.current.parent.path,
          'dartpad_ui',
          'web',
          'require.js',
        ),
      ),
      artifactsDir,
    );

    // flutter.js: the flutter_tools web bootstrap script
    // (_flutter.loader.loadEntrypoint).
    final flutterWebSdkRoot = path.dirname(sdk.flutterWebSdkPath);
    copy(
      getFile(path.join(flutterWebSdkRoot, 'flutter_js', 'flutter.js')),
      artifactsDir,
    );

    // canvaskit/: the engine renderer the shell points canvasKitBaseUrl at.
    _copyDirectory(
      getDir(path.join(flutterWebSdkRoot, 'canvaskit')),
      getDir(path.join(artifactsDir.path, 'canvaskit')),
    );
  }

  // App-facing engine assets the compiled app fetches at the server root
  // (the shell sets assetBase: '/'), staged under artifacts/ so the existing
  // route serves them at /assets/<...>. The engine always requests
  // FontManifest.json on boot; without it every Icons.* glyph renders as a
  // tofu box. This is intentionally a fixed, minimal manifest: compiled apps
  // have no pubspec-declared assets of their own today, and the general
  // per-app asset pipeline is a separate (deferred) redesign.
  final assetsDir = getDir(path.join(artifactsDir.path, 'assets'));
  copy(
    getFile(
      path.join(
        sdk.flutterBinPath,
        'cache',
        'artifacts',
        'material_fonts',
        'MaterialIcons-Regular.otf',
      ),
    ),
    getDir(path.join(assetsDir.path, 'fonts')),
  );
  joinFile(assetsDir, ['FontManifest.json']).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(const [
          {
            'family': 'MaterialIcons',
            'fonts': [
              {'asset': 'fonts/MaterialIcons-Regular.otf'},
            ],
          },
        ])}\n',
  );
}

/// Recursively copies the contents of [source] into [destination].
void _copyDirectory(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entity in source.listSync(recursive: true)) {
    if (entity is File) {
      final target = path.join(
        destination.path,
        path.relative(entity.path, from: source.path),
      );
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

@Task('Update generated files and run all checks prior to deployment')
@Depends(buildProjectTemplates)
void deploy() {}

Future<void> _run(
  String executable, {
  List<String> arguments = const [],
  String? workingDirectory,
  Map<String, String> environment = const {},
}) async {
  final process = await runWithLogging(
    executable,
    arguments: arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    log: log,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    fail('Unable to exec $executable, failed with code $exitCode');
  }
}

@Task('Update pubspec dependency versions')
void updatePubDependencies() async {
  final sdk = Sdk.fromLocalFlutter();
  await _updateDependenciesFile(channel: sdk.channel, sdk: sdk);
}

/// Updates the "dependencies file".
///
/// The new set of dependency packages, and their version numbers, is determined
/// by resolving versions of direct and indirect dependencies of a Flutter web
/// app in a scratch pub package.
///
/// See [_pubDependenciesFile] for the location of the dependencies files.
Future<void> _updateDependenciesFile({
  required String channel,
  required Sdk sdk,
}) async {
  final tempDir = Directory.systemTemp.createTempSync('pubspec-scratch');

  final pubspec = createPubspec(
    includeFlutterWeb: true,
    dartLanguageVersion: sdk.dartVersion,
    dependencies: {
      'lints': 'any',
      for (final package in supportedFlutterPackages) package: 'any',
      for (final package in supportedBasicDartPackages) package: 'any',
    },
  );
  joinFile(tempDir, ['pubspec.yaml']).writeAsStringSync(pubspec);
  await runFlutterPubGet(sdk, tempDir.path, log: log);
  final packageVersions = packageVersionsFromPubspecLock(tempDir.path);

  final deps = const JsonEncoder.withIndent('  ').convert(packageVersions);
  _pubDependenciesFile(channel: channel).writeAsStringSync('$deps\n');
}

/// Returns the File containing the pub dependencies and their version numbers.
///
/// The file is at `tool/dependencies/pub_dependencies_{channel}.json`, for
/// the Flutter channels: stable, beta, main.
File _pubDependenciesFile({required String channel}) {
  return File(
    path.join(
      Directory.current.path,
      'tool',
      'dependencies',
      'pub_dependencies_$channel.json',
    ),
  );
}

/// Builds the fitd one-engine grid SHELL bundle (WI-060) into
/// `artifacts/grid_shell/main.dart.js`, using the SAME pinned SDK and the
/// framework summary produced by [buildStorageArtifacts] — the I-123
/// corridor: shell, fragments and runtime are all grounded by ONE SDK, so
/// this must run in the same image build as `build-storage-artifacts`
/// (after it: it consumes `artifacts/flutter_web.dill`).
///
/// Mechanical recipe (proven in scratch/fitd-oneengine-grid):
///  * fixed package name `fitd_shell` (pubspec + package_config, both agree)
///  * lib/main.dart from `tool/grid_shell/lib/main.dart`
///  * generated boot.dart (v1 engine-boot mechanics — the shell is the one
///    process in the grid that boots a Flutter engine) + 2-line entry.dart,
///    all imports ABSOLUTE `package:fitd_shell/...` (relative-import
///    canonicalization in new-DDC is unreliable)
///  * emitted module names are grep-asserted before the bundle is copied
@Task('Build the fitd grid shell bundle into artifacts/grid_shell/')
Future<void> buildGridShell() async {
  final sdk = Sdk.fromLocalFlutter();
  final summary = File(path.join('artifacts', 'flutter_web.dill'));
  if (!summary.existsSync()) {
    throw StateError(
        'artifacts/flutter_web.dill missing — run `build-storage-artifacts` '
        'BEFORE `build-grid-shell` (the shell compiles against that '
        'summary; one pinned SDK grounds everything)');
  }

    const slug = 'fitd_shell';
    final temp = Directory.systemTemp.createTempSync('fitd_grid_shell');
    try {
      _copyProjectTemplate(sdk, temp.path, package: slug);
      final libDir = path.join(temp.path, 'lib');
      File(path.join(libDir, 'main.dart')).writeAsStringSync(
          File(path.join('tool', 'grid_shell', 'lib', 'main.dart'))
              .readAsStringSync());
      File(path.join(libDir, 'boot.dart')).writeAsStringSync(
          File(path.join('tool', 'grid_shell', 'boot.dart.tmpl'))
              .readAsStringSync());
      File(path.join(libDir, 'entry.dart')).writeAsStringSync(
          File(path.join('tool', 'grid_shell', 'entry.dart.tmpl'))
              .readAsStringSync());

      final dartBin = path.join(sdk.dartSdkPath, 'bin', 'dart');
      final outJs = path.join(temp.path, 'main.dart.js');
      final dartdevc = path.join(
          sdk.dartSdkPath, 'bin', 'snapshots', 'dartdevc.dart.snapshot');
      // NOTE: sdk.flutterWebSdkPath already ends in /kernel.
      final outlinePath =
          path.join(sdk.flutterWebSdkPath, 'ddc_outline_sound.dill');
      final outline = File(outlinePath).existsSync()
          ? outlinePath
          : path.join(sdk.flutterWebSdkPath, 'ddc_outline.dill');
      final args = <String>[
        dartdevc,
        '--modules=ddc',
        '--canary',
        '--reload-delta-kernel=${path.join(temp.path, 'new_kernel.dill')}',
        '--no-summarize',
        '-s',
        summary.path,
        '-s',
        outline,
        '-o',
        outJs,
        '--enable-asserts',
        path.join(libDir, 'entry.dart'),
        '--packages=${path.join(temp.path, '.dart_tool', 'package_config.json')}',
      ];
      final proc = await Process.run(dartBin, args);
      if (proc.exitCode != 0) {
        fail('grid shell compile failed (exit ${proc.exitCode}):\n'
            '[stdout] ${proc.stdout}\n[stderr] ${proc.stderr}');
      }
      final js = File(outJs).readAsStringSync();
      // Corridor tripwire: the entry library must register under its absolute
      // package name — the shell page's runMain target depends on it.
      if (!js.contains(
          'dartDevEmbedder.defineLibrary("package:$slug/entry.dart"')) {
        fail('grid shell module names did not canonicalize (no '
            'package:$slug/entry.dart in the output) — template/SDK mismatch');
      }

    final outDir = Directory(path.join('artifacts', 'grid_shell'))
      ..createSync(recursive: true);
    File(path.join(outDir.path, 'main.dart.js')).writeAsStringSync(js);
    log('grid shell bundle: ${path.join(outDir.path, 'main.dart.js')} '
        '(${js.length} bytes, entry=package:$slug/entry.dart)');
  } finally {
    temp.deleteSync(recursive: true);
  }
}

/// Copies the flutter_project template into [target] and renames the
/// package to [package] (pubspec + package_config — both must agree).
void _copyProjectTemplate(Sdk sdk, String target, {required String package}) {
  final template =
      path.join(Directory.current.path, 'project_templates', 'flutter_project');
  Directory(target).createSync(recursive: true);
  for (final entity in Directory(template).listSync(recursive: true)) {
    final copyTo =
        path.join(target, path.relative(entity.path, from: template));
    if (entity is Directory) {
      Directory(copyTo).createSync(recursive: true);
    } else if (entity is File) {
      entity.copySync(copyTo);
    } else if (entity is Link) {
      Link(copyTo).createSync(entity.targetSync(), recursive: true);
    }
  }
  final pubspecFile = File(path.join(target, 'pubspec.yaml'));
  final pubspec = pubspecFile.readAsStringSync();
  pubspecFile.writeAsStringSync(
      pubspec.replaceFirst('name: dartpad_sample', 'name: $package'));
  final cfgPath = path.join(target, '.dart_tool', 'package_config.json');
  final cfg = jsonDecode(File(cfgPath).readAsStringSync()) as Map;
  for (final pkg in (cfg['packages'] as List).cast<Map<String, dynamic>>()) {
    if (pkg['name'] == 'dartpad_sample') {
      pkg['name'] = package;
    }
  }
  File(cfgPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(cfg));
}
