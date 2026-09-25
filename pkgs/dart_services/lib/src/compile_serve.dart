// Flutter in the Dark: self-hosted serving of compiled DDC output.
//
// Implements the production compile+serve contract:
//   POST /api/v3/compileAndServe {source} -> {id, url, jsUrl, expiresAt}
//                                             | 400 {error, problems[]}
//   GET  /compiled/<id>              -> chromeless HTML runner shell
//   GET  /compiled/<id>/main.dart.js -> the compiled DDC JS
//   GET  /assets/<...>               -> app-facing engine assets the shell's
//                                       assetBase: '/' points at the server
//                                       root (FontManifest.json, MaterialIcons
//                                       font) — staged under artifacts/assets/
//                                       by grind and mounted in
//                                       common_server.dart.
//
// The HTML shell bootstraps the new-DDC ("library bundle") module system the
// same way dartpad_ui's frame does (require.js + ddc_module_loader +
// dart_sdk_new + flutter_web_new), but entirely self-hosted: every asset is
// served from this backend's /artifacts/ directory and the compiled output
// from this backend itself. No dartpad.dev runtime dependency.

import 'dart:async';
import 'dart:convert';

import 'package:dartpad_shared/model.dart' as api;
import 'package:shelf/shelf.dart';

import 'common_server.dart';
import 'compiling.dart';
import 'utils.dart';

final _jsonEncoder = const JsonEncoder.withIndent(' ');

const _jsonHeaders = <String, String>{
  'Access-Control-Allow-Origin': '*',
  'Content-Type': 'application/json; charset=utf-8',
};

Response _notFound(String id) => Response.notFound(
  _jsonEncoder.convert({'error': 'not_found_or_expired', 'id': id}),
  headers: _jsonHeaders,
  encoding: utf8,
);

/// Store entries expire after this long without a read.
const _storeTtl = Duration(hours: 2);

/// Periodic sweep interval for expired entries.
const _sweepInterval = Duration(minutes: 15);

class _CompiledApp {
  final String js;
  final bool isFlutter;
  final DateTime createdAt;
  DateTime lastAccessedAt;

  _CompiledApp({
    required this.js,
    required this.isFlutter,
    required this.createdAt,
    required this.lastAccessedAt,
  });

  bool get expired => DateTime.now().difference(lastAccessedAt) > _storeTtl;
}

/// Compile + serve, layered on top of the shared [CommonServerImpl] so the
/// same [Compiler] (and its single DDC worker pool) is reused.
class CompileServe {
  final CommonServerImpl _impl;

  /// Content-hash id -> compiled app.
  final Map<String, _CompiledApp> _store = {};
  Timer? _sweeper;

  /// Serializes compiles exactly like the REST compile endpoints.
  final TaskScheduler _scheduler = TaskScheduler();

  CompileServe(this._impl);

  void start() {
    _sweeper ??= Timer.periodic(_sweepInterval, (_) {
      _store.removeWhere((_, app) => app.expired);
    });
  }

  Future<void> shutdown() async {
    _sweeper?.cancel();
  }

  /// POST /api/v3/compileAndServe  {source: string}
  ///
  /// Flutter sources compile in the v2 grid-fragment format (fitd one-engine
  /// grid shell): the response additionally carries `{slug, entryUri,
  /// moduleUri}` so callers can mount the widget inside an already-running
  /// shell. The FNV-of-JS id and URL scheme are UNCHANGED. Non-Flutter
  /// sources compile through the legacy path and omit those fields.
  Future<Response> handleCompileAndServe(
    Request request,
    String apiVersion,
  ) async {
    if (apiVersion != api3) {
      return Response.notFound('unhandled api version: $apiVersion');
    }

    final compileRequest = api.CompileRequest.fromJson(
      await request.readAsJson(),
    );

    final compilation = await _scheduler.schedule(
      ClosureTask(
        () => _impl.compiler.compileNewDDCGrid(compileRequest.source),
        timeoutDuration: const Duration(minutes: 5),
      ),
    );

    if (!compilation.results.hasOutput) {
      return Response.badRequest(
        body: _jsonEncoder.convert({
          'error': 'compile_failed',
          'problems': compilation.results.problems.map((p) => p.message).toList(),
        }),
        headers: _jsonHeaders,
        encoding: utf8,
      );
    }

    final js = compilation.results.compiledJS!;
    final id = _idFor(js);
    final now = DateTime.now();
    _store[id] = _CompiledApp(
      js: js,
      isFlutter: _looksFlutter(js),
      createdAt: now,
      lastAccessedAt: now,
    );

    return Response.ok(
      _jsonEncoder.convert({
        'id': id,
        'url': '/compiled/$id',
        'jsUrl': '/compiled/$id/main.dart.js',
        'expiresAt': now.add(_storeTtl).toIso8601String(),
        if (compilation.slug != null) 'slug': compilation.slug,
        if (compilation.slug != null) 'entryUri': compilation.entryUri,
        if (compilation.slug != null) 'moduleUri': compilation.moduleUri,
      }),
      headers: _jsonHeaders,
      encoding: utf8,
    );
  }

  /// GET /grid/shell — the fitd one-engine grid shell page (WI-060).
  ///
  /// One PERMANENT Flutter engine that hosts many v2 grid fragments as
  /// in-tree tiles. The shell BUNDLE is an image artifact
  /// (`/artifacts/grid_shell/main.dart.js`, built by the `build-grid-shell`
  /// grind task with the SAME pinned SDK as every other artifact — the
  /// I-123 corridor). Served no-store like the per-compile runner shell.
  Response handleGridShell(Request request) {
    return Response.ok(
      _gridShellHtml(),
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
      },
      encoding: utf8,
    );
  }

  /// GET /compiled/id — chromeless runner shell.
  Response handleServeShell(Request request, String id) {
    final app = _lookup(id);
    if (app == null) return _notFound(id);

    return Response.ok(
      _shellHtml(app, id),
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        // Never cache the shell: trivially regenerated, and a stale shell
        // pinning a dead id is worse than a re-fetch.
        'Cache-Control': 'no-store',
      },
      encoding: utf8,
    );
  }

  /// GET /compiled/id/main.dart.js — the compiled JS.
  Response handleServeJs(Request request, String id) {
    final app = _lookup(id);
    if (app == null) return _notFound(id);

    return Response.ok(
      app.js,
      headers: {
        'Content-Type': 'application/javascript; charset=utf-8',
        // The id is a content hash, so this is immutable.
        'Cache-Control': 'max-age=3600, public',
        'Access-Control-Allow-Origin': '*',
      },
      encoding: utf8,
    );
  }

  _CompiledApp? _lookup(String id) {
    final app = _store[id];
    if (app == null) return null;
    if (app.expired) {
      _store.remove(id);
      return null;
    }
    app.lastAccessedAt = DateTime.now();
    return app;
  }

  /// Content-addressed id: FNV-1a 64-bit hash of the JS, hex-encoded.
  /// Deterministic (the same source compiles to the same JS), so re-compiles
  /// of an unchanged app re-use the same URL. Not security-sensitive — the id
  /// is only a lookup key into an in-memory store on our own backend.
  static String _idFor(String js) {
    const fnvPrime = 0x100000001b3;
    const fnvOffset = 0xcbf29ce484222325;
    var hash = fnvOffset;
    for (final unit in utf8.encode(js)) {
      hash ^= unit;
      hash = (hash * fnvPrime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static bool _looksFlutter(String js) =>
      js.contains('package:flutter/') || js.contains('flutter_web');
}

String _shellHtml(_CompiledApp app, String id) {
  // All URLs are server-root-absolute so the shell works regardless of any
  // path prefix the iframe is embedded under.
  const artifactsBase = '/artifacts/';
  final jsUrl = '/compiled/$id/main.dart.js';

  final flutterRequire = app.isFlutter
      ? 'require(["dart_sdk_new", "flutter_web_new"], contextLoaded);'
      : 'require(["dart_sdk_new"], contextLoaded);';

  return '''<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Flutter in the Dark</title>
  <style>
    /* Always dark: this shell is embedded by Flutter in the Dark, which is dark-only
       (ThemeMode.dark). The iframe document can't see the Flutter app's
       theme — prefers-color-scheme here reflects the OS, not the embedder —
       so a media query would white-flash light-OS users inside the dark UI. */
    html, body { margin: 0; padding: 0; height: 100%; background: #121212; }
    #fitd-status {
      position: absolute; inset: 0; display: flex; align-items: center;
      justify-content: center; font: 14px/1.4 system-ui, sans-serif;
      color: #b3b3b3;
    }
  </style>
  <script src="${artifactsBase}require.js"></script>
  <script src="${artifactsBase}flutter.js"></script>
</head>
<body>
  <div id="fitd-status">loading&hellip;</div>
  <script>
    // The bootstrap (kBootstrapFlutterCode / kBootstrapDartCode) reports
    // framework errors through this global.
    window.reportFlutterError = function(message) {
      console.error('[flutter]', message);
      try {
        parent.postMessage({sender: 'fitd-frame', type: 'stderr',
                            message: String(message)}, '*');
      } catch (_) {}
    };

    window.onerror = function(message, url, line, column, error) {
      var el = document.getElementById('fitd-status');
      if (el && !window.__fitdStarted) {
        el.textContent = 'failed to start: ' + message;
      }
      try {
        parent.postMessage({sender: 'fitd-frame', type: 'jserr',
                            message: String(message)}, '*');
      } catch (_) {}
    };

    function dartPrint(message) {
      console.log('[app]', message);
      try {
        parent.postMessage({sender: 'fitd-frame', type: 'stdout',
                            message: String(message)}, '*');
      } catch (_) {}
    }

    require.config({
      baseUrl: '$artifactsBase',
      waitSeconds: 60,
      onNodeCreated: function(node) {
        node.setAttribute('crossorigin', 'anonymous');
      }
    });

    fetch('$jsUrl')
      .then(function(r) {
        if (!r.ok) throw new Error('compiled js: HTTP ' + r.status);
        return r.text();
      })
      .then(function(compiledJs) {
        // Scope __ddcInitCode exactly like dartpad_ui's frame decorator.
        var wrapped =
          '{ let __ddcInitCode = function() {' + compiledJs + '};' +
          ' function contextLoaded() {' +
          '   __ddcInitCode();' +
          '   window.__fitdStarted = true;' +
          '   var el = document.getElementById("fitd-status");' +
          '   if (el) el.style.display = "none";' +
          '   dartDevEmbedder.runMain("package:dartpad_sample/bootstrap.dart", {});' +
          '   parent.postMessage({sender: "fitd-frame", type: "bootdone", ts: Math.round(performance.now())}, "*");' +
          ' }' +
          ' function moduleLoaderLoaded() { $flutterRequire }' +
          ' require(["ddc_module_loader"], moduleLoaderLoaded); }';

        _flutter.loader.loadEntrypoint({
          entrypointUrl: URL.createObjectURL(
            new Blob([wrapped], {type: 'text/javascript'})),
          onEntrypointLoaded: async function(engineInitializer) {
            var appRunner = await engineInitializer.initializeEngine({
              canvasKitBaseUrl: '${artifactsBase}canvaskit/',
              assetBase: '/',
            });
            appRunner.runApp();
          }
        });
      })
      .catch(function(err) {
        var el = document.getElementById('fitd-status');
        if (el) el.textContent = 'failed to load: ' + err.message;
        try {
          parent.postMessage({sender: 'fitd-frame', type: 'jserr',
                              message: String(err)}, '*');
        } catch (_) {}
      });
  </script>
</body>
</html>
''';
}

/// The grid shell page. Same loader mechanics as [_shellHtml], pointed at
/// the permanent shell bundle. The shell (not this page) owns the
/// `__fitdGrid` bridge; this page only forwards uncaught JS errors to it
/// (raw Timer/microtask throws from fragment code bypass the Flutter zone
/// — spike-measured — so the page handler is load-bearing, not cosmetic)
/// and reports boot progress to the parent via the `fitd-frame` pattern.
String _gridShellHtml() {
  const artifactsBase = '/artifacts/';
  const shellJs = '${artifactsBase}grid_shell/main.dart.js';
  const shellEntry = 'package:fitd_shell/entry.dart';

  return '''<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>fitd grid shell</title>
  <style>
    html, body { margin: 0; padding: 0; height: 100%; background: #121212; }
    #fitd-status {
      position: absolute; inset: 0; display: flex; align-items: center;
      justify-content: center; font: 14px/1.4 system-ui, sans-serif;
      color: #b3b3b3;
    }
  </style>
  <script src="${artifactsBase}require.js"></script>
  <script src="${artifactsBase}flutter.js"></script>
  <script>
    // Forward uncaught JS errors into the shell's watchdog — async errors
    // from fragment Timers/microtasks NEVER reach the Flutter zone on web.
    window.onerror = function(message, source, lineno, colno, error) {
      try {
        var grid = window.__fitdGrid;
        if (grid && grid.jsError) {
          grid.jsError(String(message), error && error.stack
            ? String(error.stack) : (source || '') + ':' + lineno);
        }
      } catch (_) {}
      try {
        parent.postMessage({sender: 'fitd-frame', type: 'jserr',
                            message: String(message)}, '*');
      } catch (_) {}
    };
  </script>
</head>
<body>
  <div id="fitd-status">booting grid shell&hellip;</div>
  <script>
    require.config({
      baseUrl: '$artifactsBase',
      waitSeconds: 90,
      onNodeCreated: function(node) {
        node.setAttribute('crossorigin', 'anonymous');
      }
    });

    fetch('$shellJs')
      .then(function(r) {
        if (!r.ok) throw new Error('grid shell js: HTTP ' + r.status);
        return r.text();
      })
      .then(function(shellJs) {
        var wrapped =
          '{ let __ddcInitCode = function() {' + shellJs + '};' +
          ' function contextLoaded() {' +
          '   __ddcInitCode();' +
          '   window.__fitdStarted = true;' +
          '   var el = document.getElementById("fitd-status");' +
          '   if (el) el.style.display = "none";' +
          '   dartDevEmbedder.runMain("$shellEntry", {});' +
          '   parent.postMessage({sender: "fitd-frame", type: "bootdone", ts: Math.round(performance.now())}, "*");' +
          ' }' +
          ' function moduleLoaderLoaded() { require(["dart_sdk_new", "flutter_web_new"], contextLoaded); }' +
          ' require(["ddc_module_loader"], moduleLoaderLoaded); }';

        _flutter.loader.loadEntrypoint({
          entrypointUrl: URL.createObjectURL(
            new Blob([wrapped], {type: 'text/javascript'})),
          onEntrypointLoaded: async function(engineInitializer) {
            var appRunner = await engineInitializer.initializeEngine({
              canvasKitBaseUrl: '${artifactsBase}canvaskit/',
              assetBase: '/',
            });
            appRunner.runApp();
          }
        });
      })
      .catch(function(err) {
        var el = document.getElementById('fitd-status');
        if (el) el.textContent = 'failed to load: ' + err.message;
        try {
          parent.postMessage({sender: 'fitd-frame', type: 'jserr',
                              message: String(err)}, '*');
        } catch (_) {}
      });
  </script>
</body>
</html>
''';
}
