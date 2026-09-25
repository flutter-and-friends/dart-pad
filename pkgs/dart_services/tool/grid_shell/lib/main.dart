// fitd one-engine grid SPIKE — the permanent shell app.
//
// Boots ONE Flutter engine and hosts many compiled challenger fragments
// (v2 widget-export fragments, one Dart package each) as in-tree tiles.
// Fragments arrive out of order; the bridge is postMessage-driven so the
// deployment eventually matches the room app's SSE state semantics.
//
// Bridge (v1 contract — mirrors what the app-side track will implement):
//   parent -> shell : {sender:'fitd-show', ver:1, type:'tiles',
//                      revision:int, tiles:[{tileId, slug, label, fragmentUrl, entryUri}]}
//                     Full-state and idempotent: revision is monotonic, the
//                     shell diffs against its current tile set (add/remove/swap).
//                     Optional {sender:'fitd-show', type:'snapshot'} asks for
//                     the report JSON.
//   shell -> parent : {sender:'fitd-shell', ver:1, type:'ready'}
//                     {sender:'fitd-shell', ver:1, type:'tileState', tileId, state, message?}
//                     {sender:'fitd-shell', ver:1, type:'report', json:<string>}
//
// Fragment contract (v2): user source defines top-level `Widget fitdApp()`;
// the generated boot registers by calling `__fitdGrid.declare(slug)` and the
// shell lazily resolves `fitdApp` from the module registry via
// `dartDevEmbedder.importLibrary('package:<slug>/main.dart').fitdApp`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

void main() {
  _startMs = DateTime.now().millisecondsSinceEpoch;
  _installErrorRouting();
  _installJsBridge();
  runApp(const FitdGridApp());
  SchedulerBinding.instance.addTimingsCallback(_onTimings);
}

// ---------------------------------------------------------------------------
// JS interop surface
// ---------------------------------------------------------------------------

@JS('dartDevEmbedder')
external JSObject get _ddc;

@JS('eval')
external JSAny? _jsEval(JSString code);

@JS('fetch')
external JSPromise<JSAny?> _jsFetch(JSString url);

JSObject get _globalContext => globalContext;

void _postToParent(Map<String, Object?> payload) {
  try {
    // The shell normally runs INSIDE a host iframe (fitd26 /show, the
    // integration harness): deliver to the PARENT window when framed, else
    // to ourselves (standalone/development pages, incl. the spike harness).
    final parent = _globalContext.getProperty('parent'.toJS);
    final target =
        parent.isA<JSObject>() ? parent as JSObject : _globalContext;
    target.callMethod('postMessage'.toJS, payload.jsify(), '*'.toJS);
  } catch (e) {
    debugPrint('[fitd-shell] postMessage failed: $e');
  }
}

// ---------------------------------------------------------------------------
// Error routing + per-tile watchdog
// ---------------------------------------------------------------------------

/// Shell layout config — the optional `config` object on the host's
/// `tiles` message (whole-object replace on every revision).
///   scrollMode 'shell' (default): internal 3-col scrollable grid (v1 behavior).
///   scrollMode 'host': FIXED-CONTENT-HEIGHT flow — the shell lays out the
///     sent tiles using the host's exact grid maths (columns, tile
///     aspect-ratio width/height, spacing), renders NO chrome and NO
///     scrolling, and emits {type:'contentSize', height} so the host sizes
///     the shard iframe; the HOST page owns scrolling.
class _ShellConfig {
  String scrollMode = 'shell';
  int? columns;
  double tileAspectRatio = 1 / 1.2; // width/height — Flutter childAspectRatio
  double spacing = 8;

  static _ShellConfig fromMap(Map? map) {
    final c = _ShellConfig();
    if (map == null) return c;
    if (map['scrollMode'] is String) c.scrollMode = map['scrollMode'] as String;
    if (map['columns'] is num) c.columns = (map['columns'] as num).toInt();
    if (map['tileAspectRatio'] is num) {
      c.tileAspectRatio = (map['tileAspectRatio'] as num).toDouble();
    }
    if (map['spacing'] is num) c.spacing = (map['spacing'] as num).toDouble();
    return c;
  }
}

_ShellConfig _config = _ShellConfig();
double? _lastEmittedContentHeight;

class _Scope {
  /// Set while the shell believes a given slug's subtree is where a build-time
  /// error came from (see [_FragmentHost]); zone errors fall back to
  /// `package:fitd_<slug>/` markers in the stack trace.
  static String? currentBuildSlug;
  static const int maxErrors = 3;
}

final Map<String, int> _slugErrorCount = {};

void _installErrorRouting() {
  FlutterError.onError = (details) {
    final text = details.toString();
    final slug =
        _slugFromText(text) ?? _Scope.currentBuildSlug;
    // RenderFlex overflow = a LAYOUT WARNING (yellow stripes), not a tile
    // failure. Recorded for observability but NOT counted as a strike.
    final strike = !text.contains('A RenderFlex overflowed') &&
        !text.contains('overflowed by') &&
        !(details.exception.toString().contains('overflowed by'));
    _recordError(slug,
        strike ? 'framework' : 'layout-warning',
        details.exception.toString(),
        strike: strike);
    debugPrint('[fitd-shell] FlutterError: ${details.exception}');
  };
  // On web, uncaught errors from fragment Timers/microtasks do NOT flow
  // through Flutter zone handlers — they surface on window.onerror; the
  // page forwards them via __fitdGrid.jsError. DDC stacks there are
  // minified (no package: markers) → attribution falls back to the error
  // MESSAGE text; unattributable errors are counted globally.
  PlatformDispatcher.instance.onError = (error, stack) {
    _recordError(_slugFromText('$stack') ?? _slugFromText('$error'),
        'zone-uncaught', error.toString());
    return true; // keep the engine alive — the watchdog decides tile demotion
  };
}

String? _slugFromText(String? text) {
  if (text == null) return null;
  final m = RegExp(r'package:(fitd_[0-9a-f]+)').firstMatch(text);
  return m?.group(1);
}

void _recordError(String? slug, String kind, String message,
    {bool strike = true}) {
  _timeline.add({
    't': _sinceStartMs(),
    'op': 'error',
    'slug': slug,
    'kind': kind,
    'message': message.length > 220 ? message.substring(0, 220) : message,
  });
  if (!strike || slug == null) return;
  final n = (_slugErrorCount[slug] ?? 0) + 1;
  _slugErrorCount[slug] = n;
  debugPrint('[fitd-shell] strike $n/${_Scope.maxErrors} for $slug');
  // Watchdog: N strikes → demote every tile showing this slug to a dead
  // placeholder. The shell and all other tiles keep running.
  if (n >= _Scope.maxErrors) {
    for (final t in _tiles.values.where((t) => t.slug == slug)) {
      if (t.state != 'dead') {
        t.state = 'dead';
        t.message = 'uncaught errors x$n — demoted by watchdog';
      }
    }
    _postStates();
  }
}

// ---------------------------------------------------------------------------
// State + bridge
// ---------------------------------------------------------------------------

int _startMs = 0;
int _sinceStartMs() => DateTime.now().millisecondsSinceEpoch - _startMs;
int _lastRevision = -1;
final List<Map<String, Object?>> _timeline = [];
final List<Map<String, Object?>> _frameSamples = [];
final Map<String, ({int start, int end})> _frameWindows = {};

final Map<String, _TileState> _tiles = {}; // tileId → state
final Map<String, bool> _declaredSlugs = {}; // slug → declared?
final Map<String, JSAny?> _factoryFns = {}; // slug → handed-over factory
final Map<String, Widget Function()> _entryFns = {}; // slug → resolved fitdApp
final Map<String, Future<void>> _slugLoading = {}; // slug → in-flight load
final Set<String> _slugFailed = {}; // slug → injection already failed
final Map<String, int> _version = {}; // tileId → subtree version (swap)

class _TileState {
  _TileState(this.tileId, this.slug, this.label);
  final String tileId;
  String slug;
  String label;
  String state = 'loading'; // loading|mounted|error|dead
  String? message;
  DateTime? mountedAt;
}

void _installJsBridge() {
  final grid = JSObject();
  grid.setProperty(
      'declare'.toJS,
      // STRICT arity: fragments call declare(slug) — a DDC-converted
      // function invoked with mismatched arg count throws NoSuchMethodError
      // with an empty message (the injected-fn variant failed exactly so
      // in the production integration run; the factory resolves via
      // importLibrary in _resolveEntryFn instead).
      ((JSString slug) {
        final key = slug.toDart;
        _declaredSlugs[key] = true;
        debugPrint('[fitd-shell] declared $key');
      })
          .toJS);
  // FYI: on web, uncaught errors from fragment Timers/microtasks do NOT go
  // through Flutter's zone handlers — they surface on window.onerror. The
  // index page forwards them here so the watchdog can attribute + demote.
  grid.setProperty(
      'jsError'.toJS,
      ((JSString message, JSString stack) {
        return _recordError(_slugFromText(stack.toDart) ?? _slugFromText(message.toDart),
            'window-uncaught', message.toDart);
      })
          .toJS);
  _globalContext.setProperty('__fitdGrid'.toJS, grid);
  _globalContext.setProperty('__fitdGridReady'.toJS, false.toJS);

  // postMessage listener (real deployment: parent app → shell).
  _globalContext.setProperty(
      'onmessage'.toJS,
      ((JSObject event) {
        try {
          final data = event.getProperty('data'.toJS);
          if (!data.isA<JSObject>()) return;
          final map = (data as JSObject).dartify();
          if (map is! Map || map['sender'] != 'fitd-show') return;
          bool framesArmed = false;
        switch (map['type']) {
          case 'tiles':
            unawaited(_applyTiles(map.cast<String, dynamic?>()));
          case 'snapshot':
            _postToParent({
              'sender': 'fitd-shell',
              'ver': 1,
              'type': 'report',
              'json': _reportJson(),
            });
          case 'phase':
            // SPIKE-ONLY: not part of the deployment bridge contract.
            final label = (map['label'] as String?) ?? '?';
            final windowMs = (map['windowMs'] as num?)?.toInt() ?? 10000;
            final now = _sinceStartMs();
            if (label.startsWith('frame-window')) {
              _frameWindows[label] = (start: now, end: now + windowMs);
              framesArmed = true;
            }
            _timeline.add({
              't': now,
              'op': 'phase',
              'label': label,
              'framesArmed': framesArmed,
            });
        }
        } catch (e) {
          debugPrint('[fitd-shell] bridge msg error: $e');
        }
      })
          .toJS);
}

Future<void> _applyTiles(Map<String, dynamic?> msg) async {
  final revision = (msg['revision'] as num?)?.toInt() ?? 0;
  if (revision <= _lastRevision) return; // idempotent, monotonic
  _lastRevision = revision;
  final newConfig = _ShellConfig.fromMap(
      (msg['config'] as Map?)?.cast<String, dynamic?>());
  final configChanged = newConfig.scrollMode != _config.scrollMode ||
      newConfig.columns != _config.columns ||
      newConfig.tileAspectRatio != _config.tileAspectRatio ||
      newConfig.spacing != _config.spacing;
  _config = newConfig;
  final desired = ((msg['tiles'] as List?) ?? const <dynamic>[])
      .whereType<Map>()
      .map((m) => m.cast<String, dynamic?>())
      .toList();
  _timeline.add({
    't': _sinceStartMs(),
    'op': 'tiles',
    'revision': revision,
    'count': desired.length,
  });

  if (configChanged) _rebuild(); // re-run layout for the new config

  final desiredIds = <String>{};
  for (final spec in desired) {
    final tileId = spec['tileId']! as String;
    final slug = spec['slug']! as String;
    final label = (spec['label'] as String?) ?? slug;
    desiredIds.add(tileId);
    final existing = _tiles[tileId];
    if (existing == null) {
      // ADD.
      final tile = _TileState(tileId, slug, label);
      _tiles[tileId] = tile;
      await _ensureFragment(tile, spec);
      _rebuild();
    } else if (existing.slug != slug) {
      // SWAP: same tile, new fragment → new subtree keys.
      _version[tileId] = (_version[tileId] ?? 0) + 1;
      _timeline.add({
        't': _sinceStartMs(),
        'op': 'swap',
        'tileId': tileId,
        'from': existing.slug,
        'to': slug,
      });
      existing
        ..slug = slug
        ..label = label
        ..state = 'loading'
        ..message = null;
      await _ensureFragment(existing, spec);
      _rebuild();
    } else if (existing.label != label) {
      existing.label = label;
      _rebuild();
    }
  }

  // REMOVE.
  final removed = _tiles.keys.where((id) => !desiredIds.contains(id)).toList();
  if (removed.isNotEmpty) {
    for (final id in removed) {
      _timeline.add({'t': _sinceStartMs(), 'op': 'remove', 'tileId': id});
      _tiles.remove(id);
    }
    _rebuild();
  }
}

/// Fetch → eval → runMain → resolve `fitdApp` for a slug (once per slug).
/// Injection timings are recorded on the timeline (JS: fetch/eval/runMain/
/// resolve; the widget mount itself is timed at first build in [_FragmentHost]).
Future<void> _ensureFragment(
    _TileState tile, Map<String, dynamic?> spec) async {
  final slug = tile.slug;
  Widget Function()? already = _entryFns[slug];
  if (already == null && _slugFailed.contains(slug)) {
    // A previous injection attempt failed; do NOT re-eval (defineLibrary
    // would throw on the duplicate). The tile keeps its error state.
    return;
  }
  if (already == null) {
    final inFlight = _slugLoading[slug];
    if (inFlight != null) {
      await inFlight; // slug is loading for a sibling tile — wait, then mount
      already = _entryFns[slug];
    }
  }
  if (already != null) {
    // Slug already available (repeat tile or back-swap) → nothing to fetch.
    tile.state = 'mounted';
    tile.message = null;
    _timeline.add({
      't': _sinceStartMs(),
      'op': 'inject-reuse',
      'slug': slug,
      'tileId': tile.tileId,
    });
    return;
  }
  final load = _loadFragment(tile, slug, spec);
  _slugLoading[slug] = load;
  return load;
}

/// Resolves a slug's widget factory: the v2 contract hands the tear-off
/// over in `__fitdGrid.declare(slug, fn)`; legacy callers register by name
/// only and are resolved from the module registry (eager init + link).
Widget Function() _resolveEntryFn(String slug) {
  final handed = _factoryFns[slug];
  if (handed != null) {
    try {
      // ignore: invalid_runtime_check_with_js_interop_types
      return handed as Widget Function();
    } catch (_) {
      throw StateError('fragment $slug handed an uncallable factory '
          '(v2 widget-export contract violated)');
    }
  }
  debugPrint('[fitd-shell] resolving module $slug via importLibrary');
  final lib = _ddc
      .callMethod('importLibrary'.toJS, 'package:$slug/main.dart'.toJS);
  debugPrint('[fitd-shell] module object: ${lib.runtimeType}');
  final Object? member = (lib as JSObject).getProperty('fitdApp'.toJS);
  debugPrint('[fitd-shell] fitdApp bean: ${member.runtimeType} = $member');
  try {
    // ignore: invalid_runtime_check_with_js_interop_types
    return member as Widget Function();
  } catch (_) {
    throw StateError('module $slug did not export a callable fitdApp() '
        '(v2 widget-export contract violated; had: ${member.runtimeType})');
  }
}

Future<void> _loadFragment(
    _TileState tile, String slug, Map<String, dynamic?> spec) async {
  final fragmentUrl = spec['fragmentUrl'] as String;
  final entryUri = (spec['entryUri'] as String?) ?? 'package:$slug/entry.dart';
  try {
    final sw = Stopwatch()..start();
    final resp = (await _jsFetch(fragmentUrl.toJS).toDart) as JSObject;
    final status = (resp.getProperty('status'.toJS) as JSNumber).toDartInt;
    if (status != 200) throw 'fetch $fragmentUrl → HTTP $status';
    final js =
        (await (resp.callMethod('text'.toJS) as JSPromise<JSString>).toDart)
            .toDart;
    final fetchMs = sw.elapsed;

    // Registers the fragment's defineLibrary entries. Indirect global scope
    // (window.eval), same effect as the production shell's function wrapper.
    _jsEval(js.toJS);
    final evalMs = sw.elapsed - fetchMs;

    // Re-invocable runMain: imports entry and invokes its main(), which
    // calls __fitdGrid.declare(slug). Synchronous → completes inline.
    _ddc.callMethod('runMain'.toJS, entryUri.toJS, JSObject());
    final runMainMs = sw.elapsed - evalMs - fetchMs;

    if (!_declaredSlugs.containsKey(slug)) {
      throw StateError('runMain($entryUri) did not reach __fitdGrid.declare '
          '— bad boot contract or stale/duplicate module name');
    }

    // importLibrary with no installFn → eager initialize + link. `fitdApp`
    // comes back as the actual Dart tear-off; cast into a typed fn so ALL
    // widget construction below is ordinary Dart.
    final lib = _ddc
        .callMethod('importLibrary'.toJS, 'package:$slug/main.dart'.toJS)
        as JSObject;
    Widget Function() fn;
    try {
      fn = lib.getProperty('fitdApp'.toJS) as Widget Function();
    } catch (_) {
      throw 'module $slug did not export a callable fitdApp() '
          '(v2 widget-export contract violated)';
    }
    _entryFns[slug] = fn;
    final resolveMs = sw.elapsed - runMainMs - evalMs - fetchMs;

    _timeline.add({
      't': _sinceStartMs(),
      'op': 'inject',
      'slug': slug,
      'tileId': tile.tileId,
      'bytesJs': js.length,
      'fetchMs': fetchMs.inMicroseconds / 1000.0,
      'evalMs': evalMs.inMicroseconds / 1000.0,
      'runMainMs': runMainMs.inMicroseconds / 1000.0,
      'resolveMs': resolveMs.inMicroseconds / 1000.0,
      'totalMs': sw.elapsed.inMicroseconds / 1000.0,
    });

    // First µs of mount: construct the root widget eagerly (the element tree
    // build happens on the next frame; [_FragmentHost] timestamps that too).
    tile.state = 'mounted';
    tile.message = null;
    _postStates();
  } catch (e) {
    _slugFailed.add(slug);
    tile.state = 'error';
    tile.message = '$e';
    _timeline.add({
      't': _sinceStartMs(),
      'op': 'inject-fail',
      'slug': slug,
      'error': '$e',
    });
    _postStates();
  } finally {
    _slugLoading.remove(slug);
  }
}

// ---------------------------------------------------------------------------
// UI: grid + tiles + fragment host
// ---------------------------------------------------------------------------

ValueNotifier<int> _rebuildTick = ValueNotifier<int>(0);
void _rebuild() {
  _rebuildTick.value = _rebuildTick.value + 1;
  _postStates();
}

void _postStates() {
  // Emit on TRANSITIONS only — a rethrowing tile re-strikes every tick and
  // would otherwise spam the host with identical messages.
  for (final t in _tiles.values) {
    final sig = '${t.state}:${t.message ?? ''}';
    if (_lastPostedState[t.tileId] == sig) continue;
    _lastPostedState[t.tileId] = sig;
    _postToParent({
      'sender': 'fitd-shell',
      'ver': 1,
      'type': 'tileState',
      'tileId': t.tileId,
      'state': t.state,
      'slug': t.slug,
      if (t.message != null) 'message': t.message,
    });
  }
}

final Map<String, String> _lastPostedState = {};

class FitdGridApp extends StatelessWidget {
  const FitdGridApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: ValueListenableBuilder<int>(
        valueListenable: _rebuildTick,
        builder: (context, _, ___) {
          // Readiness signal for the driver: first real build = engine up.
          _declareReady();
          return _GridBody();
        },
      ),
    );
  }

  static bool _readySent = false;
  static void _declareReady() {
    if (_readySent) return;
    _readySent = true;
    _globalContext.setProperty('__fitdGridReady'.toJS, true.toJS);
    _postToParent({
      'sender': 'fitd-shell',
      'ver': 1,
      'type': 'ready',
    });
    _timeline.add({'t': _sinceStartMs(), 'op': 'ready'});
  }
}

class _GridBody extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ids = _tiles.keys.toList();
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Text('fitd one-engine grid — ${ids.length} tiles',
                    style: const TextStyle(color: Colors.white70)),
                const Spacer(),
                Text(
                  'mounted=${_tiles.values.where((t) => t.state == "mounted").length} '
                  'errors=${_tiles.values.where((t) => t.state == "error" || t.state == "dead").length}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
          Expanded(
            child: _config.scrollMode == 'host'
                ? _HostChunkBody(tiles: [
                    for (final id in ids) _tiles[id]!,
                  ])
                : ids.isEmpty
                    ? const Center(
                        child: Text('waiting for fragments…',
                            style: TextStyle(color: Colors.white24)))
                    : LayoutBuilder(builder: (context, c) {
                        const cols = 3;
                        final tw = (c.maxWidth / cols).floorToDouble();
                        final th = tw * 0.75;
                        return GridView.count(
                          crossAxisCount: cols,
                          childAspectRatio: tw / th,
                          padding: const EdgeInsets.all(8),
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                          children: [
                            for (final id in ids)
                              _TileCard(key: ValueKey(id), tile: _tiles[id]!),
                          ],
                        );
                      }),
          ),
        ],
      ),
    );
  }
}

/// `scrollMode:'host'` layout: fixed-content-height chunk — exact host grid
/// maths (columns/tileAspectRatio/spacing), zero internal scrolling, emits
/// the content height so the host sizes the shard iframe.
class _HostChunkBody extends StatelessWidget {
  const _HostChunkBody({required this.tiles});
  final List<_TileState> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final columns = (_config.columns ?? 3).clamp(1, 24);
      final spacing = _config.spacing;
      final tileW =
          (constraints.maxWidth - spacing * (columns + 1)) / columns;
      final tileH = tileW / _config.tileAspectRatio;
      final rows = (tiles.length + columns - 1) ~/ columns;
      final contentH = spacing + rows * tileH + rows * spacing;
      if (contentH != _lastEmittedContentHeight) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (contentH == _lastEmittedContentHeight) return;
          _lastEmittedContentHeight = contentH;
          _postToParent({
            'sender': 'fitd-shell',
            'ver': 1,
            'type': 'contentSize',
            'height': (contentH * 100).roundToDouble() / 100,
          });
        });
      }
      return Padding(
        padding: EdgeInsets.all(spacing),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var r = 0; r < rows; r++)
              Padding(
                padding: EdgeInsets.only(top: spacing),
                child: SizedBox(
                  height: tileH,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var c = 0; c < columns; c++)
                        Padding(
                          padding: EdgeInsets.only(left: spacing),
                          child: SizedBox(
                            width: tileW,
                            height: tileH,
                            child: (r * columns + c) < tiles.length
                                ? _TileCard(
                                    key: ValueKey(
                                        tiles[r * columns + c].tileId),
                                    tile: tiles[r * columns + c],
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }
}

class _TileCard extends StatelessWidget {
  const _TileCard({super.key, required this.tile});
  final _TileState tile;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: switch (tile.state) {
          'mounted' => const Color(0xFF2E7D32),
          'dead' => const Color(0xFFB71C1C),
          'error' => const Color(0xFFF57F17),
          _ => const Color(0xFF30363D),
        }),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: const BoxDecoration(
              color: Color(0xFF161B22),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Text(
              '${tile.label}  ·  ${tile.state}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
          ),
          Expanded(
            child: _TileContent(tile: tile),
          ),
        ],
      ),
    );
  }
}

class _TileContent extends StatelessWidget {
  const _TileContent({required this.tile});
  final _TileState tile;

  @override
  Widget build(BuildContext context) {
    return switch (tile.state) {
      'loading' => const Center(
          child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))),
      'mounted' => _FragmentHost(
          key: ValueKey('v${_version[tile.tileId] ?? 0}:${tile.slug}'),
          slug: tile.slug),
      _ => Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              tile.message ?? tile.state,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 10,
                  color: tile.state == 'dead'
                      ? const Color(0xFFB71C1C)
                      : const Color(0xFFF57F17)),
            ),
          ),
        ),
    };
  }
}

/// Mounts one fragment's widget. Fresh subtree per slug↔version (keys above).
/// Wrap in RepaintBoundary for per-tile paint isolation, and attribute
/// build-time errors to this tile via [_Scope.currentBuildSlug].
class _FragmentHost extends StatelessWidget {
  const _FragmentHost({super.key, required this.slug});
  final String slug;

  @override
  Widget build(BuildContext context) {
    final fn = _entryFns[slug];
    if (fn == null) {
      return const Center(
          child: Text('fragment not resolved',
              style: TextStyle(color: Colors.amber, fontSize: 10)));
    }
    // Attribution heuristic: leave the slug set. Flux builds walk subtree
    // by subtree — if the framework catches a build error inside THIS
    // subtree, currentBuildSlug is still this tile (a later host build
    // overwrites it). Zone errors arrive later and fall back to stack
    // markers instead (this heuristic only feeds FlutterError.onError).
    _Scope.currentBuildSlug = slug;
    Widget w;
    try {
      // RepaintBoundary = paint isolation; ClipRect = fragments paint
      // full-bleed (found in the spike: CustomPainter Clip.none lets one
      // tile's canvas paint bleed into neighbours).
      w = ClipRect(child: RepaintBoundary(child: fn()));
    } catch (e) {
      _recordError(slug, 'mount-construct', e.toString());
      _Scope.currentBuildSlug = null;
      w = Center(
          child: Text('build threw: $e',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red, fontSize: 10)));
    }
    return w;
  }
}

// ---------------------------------------------------------------------------
// Frame timing + report
// ---------------------------------------------------------------------------

void _onTimings(List<FrameTiming> timings) {
  // Ring buffer; report slices by each armed phase window.
  final tNow = _sinceStartMs();
  if (_frameSamples.length < 4000) {
    for (final f in timings) {
      final buildMs =
          (f.buildDuration + f.rasterDuration).inMicroseconds / 1000.0;
      _frameSamples.add({
        't': tNow,
        'buildMs': f.buildDuration.inMicroseconds / 1000.0,
        'rasterMs': f.rasterDuration.inMicroseconds / 1000.0,
        'totalMs': buildMs,
      });
    }
  }
}

double _pct(List<double> xs, double p) {
  if (xs.isEmpty) return double.nan;
  final s = xs..sort();
  return s[((s.length - 1) * p).floor()];
}

Map<String, Object?> _frameWindowReport(
    String label, ({int start, int end}) win) {
  final frames = _frameSamples
      .where((f) => (f['t'] as int) >= win.start - 300 &&
          (f['t'] as int) <= win.end + 300)
      .toList();
  final builds = [for (final f in frames) f['buildMs']! as double];
  final rasters = [for (final f in frames) f['rasterMs']! as double];
  final totals = [for (final f in frames) f['totalMs']! as double];
  double mb(double v) => (v * 100).roundToDouble() / 100;
  // Correct FPS = frames / real window length (raster-bound pipelines skip
  // frames; count/10s alone would hide how MUCH slower than vsync we run).
  final fps = frames.length / ((win.end - win.start) / 1000);
  final intervals = <double>[];
  for (var i = 1; i < frames.length; i++) {
    final tPrev = frames[i - 1]['t'] as int;
    final tNow2 = frames[i]['t'] as int;
    intervals.add((tNow2 - tPrev).toDouble());
  }
  return {
    'label': label,
    'frames': frames.length,
    'fpsMeasured': (fps * 10).roundToDouble() / 10,
    'frameIntervalMsP50': mb(_pct(intervals, 0.5)),
    'frameIntervalMsP95': mb(_pct(intervals, 0.95)),
    'buildMsP50': mb(_pct(builds, 0.5)),
    'buildMsP95': mb(_pct(builds, 0.95)),
    'rasterMsP50': mb(_pct(rasters, 0.5)),
    'rasterMsP95': mb(_pct(rasters, 0.95)),
    'totalMsP50': mb(_pct(totals, 0.5)),
    'totalMsP95': mb(_pct(totals, 0.95)),
  };
}

String _reportJson() {
  final report = <String, Object?>{
    'bootReadyMs': (_timeline.firstWhere((e) => e['op'] == 'ready',
                orElse: () => const {'t': -1})['t'] as int? ?? -1),
    'platform': _platformNote,
    'tiles': [
      for (final t in _tiles.values)
        {'tileId': t.tileId, 'slug': t.slug, 'state': t.state},
    ],
    'frameWindows': [
      for (final e in _frameWindows.entries)
        _frameWindowReport(e.key, e.value),
    ],
    'errors': [for (final e in _slugErrorCount.entries) {'slug': e.key, 'count': e.value}],
    'timeline': _timeline,
  };
  return jsonEncode(report);
}

const String _platformNote = 'chrome-headless_swiftshader (set from driver)';
