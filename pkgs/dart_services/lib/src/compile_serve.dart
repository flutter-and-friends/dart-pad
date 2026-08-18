// fitd26: self-hosted serving of compiled DDC output.
//
// Implements the production compile+serve contract:
//   POST /api/v3/compileAndServe {source} -> {id, url, jsUrl, expiresAt}
//                                             | 400 {error, problems[]}
//   GET  /compiled/<id>              -> chromeless HTML runner shell
//   GET  /compiled/<id>/main.dart.js -> the compiled DDC JS
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

    final results = await _scheduler.schedule(
      ClosureTask(
        () => _impl.compiler.compileNewDDC(compileRequest.source),
        timeoutDuration: const Duration(minutes: 5),
      ),
    );

    if (!results.hasOutput) {
      return Response.badRequest(
        body: _jsonEncoder.convert({
          'error': 'compile_failed',
          'problems': results.problems.map((p) => p.message).toList(),
        }),
        headers: _jsonHeaders,
        encoding: utf8,
      );
    }

    final js = results.compiledJS!;
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
      }),
      headers: _jsonHeaders,
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
  <title>fitd26</title>
  <style>
    html, body { margin: 0; padding: 0; height: 100%; background: #fff; }
    #fitd26-status {
      position: absolute; inset: 0; display: flex; align-items: center;
      justify-content: center; font: 14px/1.4 system-ui, sans-serif;
      color: #666;
    }
  </style>
  <script src="${artifactsBase}require.js"></script>
  <script src="${artifactsBase}flutter.js"></script>
</head>
<body>
  <div id="fitd26-status">loading&hellip;</div>
  <script>
    // The bootstrap (kBootstrapFlutterCode / kBootstrapDartCode) reports
    // framework errors through this global.
    window.reportFlutterError = function(message) {
      console.error('[flutter]', message);
      try {
        parent.postMessage({sender: 'fitd26-frame', type: 'stderr',
                            message: String(message)}, '*');
      } catch (_) {}
    };

    window.onerror = function(message, url, line, column, error) {
      var el = document.getElementById('fitd26-status');
      if (el && !window.__fitd26Started) {
        el.textContent = 'failed to start: ' + message;
      }
      try {
        parent.postMessage({sender: 'fitd26-frame', type: 'jserr',
                            message: String(message)}, '*');
      } catch (_) {}
    };

    function dartPrint(message) {
      console.log('[app]', message);
      try {
        parent.postMessage({sender: 'fitd26-frame', type: 'stdout',
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
          '   window.__fitd26Started = true;' +
          '   var el = document.getElementById("fitd26-status");' +
          '   if (el) el.style.display = "none";' +
          '   dartDevEmbedder.runMain("package:dartpad_sample/bootstrap.dart", {});' +
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
        var el = document.getElementById('fitd26-status');
        if (el) el.textContent = 'failed to load: ' + err.message;
        try {
          parent.postMessage({sender: 'fitd26-frame', type: 'jserr',
                              message: String(err)}, '*');
        } catch (_) {}
      });
  </script>
</body>
</html>
''';
}
