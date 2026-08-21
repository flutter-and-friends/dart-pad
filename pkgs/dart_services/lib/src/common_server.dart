// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartpad_shared/model.dart' as api;
import 'package:dartpad_shared/ws.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'analysis.dart';
import 'caching.dart';
import 'compile_serve.dart';
import 'compiling.dart';

import 'generative_ai.dart';
import 'logging.dart';
import 'project_templates.dart';
import 'pub.dart';
import 'sdk.dart';
import 'shelf_cors.dart' as shelf_cors;
import 'utils.dart';

const jsonContentType = 'application/json; charset=utf-8';

const apiPrefix = '/api/<apiVersion>';

const api3 = 'v3';

final log = DartPadLogger('common_server');

class CommonServerImpl {
  final Sdk sdk;
  final ServerCache cache;

  late final Analyzer analyzer;
  late final Compiler compiler;
  final GenerativeAI ai = GenerativeAI();

  CommonServerImpl(this.sdk, this.cache);

  Future<void> init() async {
    log.fine('initializing CommonServerImpl');

    analyzer = Analyzer(sdk);
    await analyzer.init();

    compiler = Compiler(sdk);
  }

  Future<void> shutdown() async {
    log.fine('shutting down CommonServerImpl');

    await cache.shutdown();

    await analyzer.shutdown();
    await compiler.dispose();
  }
}

class CommonServerApi {
  final CommonServerImpl impl;
  final TaskScheduler scheduler = TaskScheduler();
  late final CompileServe compileServe = CompileServe(impl)..start();

  /// The shelf router.
  late final Router router = () {
    final router = Router();

    // general requests (GET)
    router.get(r'/api/<apiVersion>/version', handleVersion);

    // websocket requests
    router.get(r'/ws', webSocketHandler(handleWebSocket));

    // serve the compiled artifacts
    final artifactsDir = Directory('artifacts');
    if (artifactsDir.existsSync()) {
      router.mount('/artifacts/', _serveCachedArtifacts(artifactsDir.path));
    }

    // serve self-hosted compiled apps (fitd26 chromeless iframe runner)
    router.get(r'/compiled/<id>', compileServe.handleServeShell);
    router.get(r'/compiled/<id>/main.dart.js', compileServe.handleServeJs);

    // general requests (POST)
    router.post(r'/api/<apiVersion>/analyze', handleAnalyze);
    router.post(r'/api/<apiVersion>/compileDDC', handleCompileDDC);
    router.post(r'/api/<apiVersion>/compileNewDDC', handleCompileNewDDC);
    router.post(
      r'/api/<apiVersion>/compileNewDDCReload',
      handleCompileNewDDCReload,
    );
    router.post(
      r'/api/<apiVersion>/compileAndServe',
      compileServe.handleCompileAndServe,
    );
    router.post(r'/api/<apiVersion>/complete', handleComplete);
    router.post(r'/api/<apiVersion>/fixes', handleFixes);
    router.post(r'/api/<apiVersion>/format', handleFormat);
    router.post(r'/api/<apiVersion>/document', handleDocument);
    router.post(r'/api/<apiVersion>/generateCode', generateCode);
    router.post(r'/api/<apiVersion>/updateCode', updateCode);
    router.post(r'/api/<apiVersion>/suggestFix', suggestFix);

    return router;
  }();

  CommonServerApi(this.impl);

  Future<void> init() => impl.init();

  Future<void> shutdown() async {
    await compileServe.shutdown();
    await impl.shutdown();
  }

  Future<Response> handleVersion(Request request, String apiVersion) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    return ok(version().toJson());
  }

  /// Handle a new websocket connection request.
  ///
  /// Handle incoming requests, convert them to exising commands and dispatch
  /// them appropriately. The commands and responses mirror the existing REST
  /// protocol.
  ///
  /// This will be a long-running connection to the client.
  void handleWebSocket(WebSocketChannel webSocket, String? subprotocol) {
    StreamSubscription<dynamic>? subscription;

    subscription = webSocket.stream.listen(
      (message) async {
        try {
          // Handle incoming WebSocket messages
          final request = JsonRpcRequest.fromJson(message as String);
          final timer = Stopwatch()..start();
          JsonRpcResponse? response;

          switch (request.method) {
            case 'version':
              response = request.createResultResponse(version().toJson());
              break;
            case 'analyze':
              final sourceRequest = api.SourceRequest.fromJson(request.params!);
              final result = await serialize(() {
                return impl.analyzer.analyze(sourceRequest.source);
              });
              response = request.createResultResponse(result.toJson());
              break;
            case 'complete':
              final sourceRequest = api.SourceRequest.fromJson(request.params!);
              final result = await serialize(
                () => impl.analyzer.complete(
                  sourceRequest.source,
                  sourceRequest.offset!,
                ),
              );
              response = request.createResultResponse(result.toJson());
              break;
            case 'document':
              final sourceRequest = api.SourceRequest.fromJson(request.params!);
              final result = await serialize(() {
                return impl.analyzer.dartdoc(
                  sourceRequest.source,
                  sourceRequest.offset!,
                );
              });
              response = request.createResultResponse(result.toJson());
              break;
            case 'fixes':
              final sourceRequest = api.SourceRequest.fromJson(request.params!);
              final result = await serialize(
                () => impl.analyzer.fixes(
                  sourceRequest.source,
                  sourceRequest.offset!,
                ),
              );
              response = request.createResultResponse(result.toJson());
              break;
            case 'format':
              final sourceRequest = api.SourceRequest.fromJson(request.params!);
              final result = await serialize(() {
                return impl.analyzer.format(
                  sourceRequest.source,
                  sourceRequest.offset,
                );
              });
              response = request.createResultResponse(result.toJson());
              break;
            case 'compileDDC':
              final compileRequest = api.CompileRequest.fromJson(
                request.params!,
              );
              final results = await serialize(() {
                return impl.compiler.compileDDC(compileRequest.source);
              });
              if (results.hasOutput) {
                response = request.createResultResponse(
                  api.CompileDDCResponse(
                    result: results.compiledJS!,
                    deltaDill: results.deltaDill,
                  ).toJson(),
                );
              } else {
                response = request.createErrorResponse(
                  results.problems.map((p) => p.message).join('\n'),
                );
              }
              break;
            case 'compileNewDDC':
              final compileRequest = api.CompileRequest.fromJson(
                request.params!,
              );
              final results = await serialize(() {
                return impl.compiler.compileNewDDC(compileRequest.source);
              });
              if (results.hasOutput) {
                response = request.createResultResponse(
                  api.CompileDDCResponse(
                    result: results.compiledJS!,
                    deltaDill: results.deltaDill,
                  ).toJson(),
                );
              } else {
                response = request.createErrorResponse(
                  results.problems.map((p) => p.message).join('\n'),
                );
              }
              break;
            case 'compileNewDDCReload':
              final compileRequest = api.CompileRequest.fromJson(
                request.params!,
              );
              final results = await serialize(() {
                return impl.compiler.compileNewDDCReload(
                  compileRequest.source,
                  compileRequest.deltaDill!,
                );
              });
              if (results.hasOutput) {
                response = request.createResultResponse(
                  api.CompileDDCResponse(
                    result: results.compiledJS!,
                    deltaDill: results.deltaDill,
                  ).toJson(),
                );
              } else {
                response = request.createErrorResponse(
                  results.problems.map((p) => p.message).join('\n'),
                );
              }
              break;
            case 'generateCode':
              final generateCodeRequest = api.GenerateCodeRequest.fromJson(
                request.params!,
              );
              final stream = impl.ai.generateCode(
                appType: generateCodeRequest.appType,
                prompt: generateCodeRequest.prompt,
                attachments: generateCodeRequest.attachments,
              );
              _streamWebsocketResponse(webSocket, request, stream);
              break;
            case 'updateCode':
              final updateCodeRequest = api.UpdateCodeRequest.fromJson(
                request.params!,
              );
              final stream = impl.ai.updateCode(
                appType: updateCodeRequest.appType,
                prompt: updateCodeRequest.prompt,
                source: updateCodeRequest.source,
                attachments: updateCodeRequest.attachments,
              );
              _streamWebsocketResponse(webSocket, request, stream);
              break;
            case 'suggestFix':
              final suggestFixRequest = api.SuggestFixRequest.fromJson(
                request.params!,
              );
              final stream = impl.ai.suggestFix(
                appType: suggestFixRequest.appType,
                message: suggestFixRequest.errorMessage,
                line: suggestFixRequest.line,
                column: suggestFixRequest.column,
                source: suggestFixRequest.source,
              );
              _streamWebsocketResponse(webSocket, request, stream);
              break;

            default:
              response = request.createErrorResponse(
                'unknown command: ${request.method}',
              );
              break;
          }

          // If response is null, that means we got a streaming request.
          if (response != null) {
            final content = jsonEncode(response.toJson());
            webSocket.sink.add(content);

            final time = timer.elapsed;
            final logMsg = _formatLog(request, time, response, content);
            log.info('[ws] $logMsg');
          }
        } catch (e) {
          log.severe('error handling websocket request', error: e);
        }
      },
      onDone: () {
        // Clean up any stream subscription.
        subscription?.cancel();
        subscription = null;
      },
      onError: (Object error) {
        log.severe('error from websocket connection', error: error);
      },
    );
  }

  Future<Response> handleAnalyze(Request request, String apiVersion) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    final sourceRequest = api.SourceRequest.fromJson(
      await request.readAsJson(),
    );

    final result = await serialize(() {
      return impl.analyzer.analyze(sourceRequest.source);
    });

    return ok(result.toJson());
  }

  Future<Response> _handleCompileDDC(
    Request request,
    String apiVersion,
    Future<DDCCompilationResults> Function(api.CompileRequest) compile,
  ) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    final compileRequest = api.CompileRequest.fromJson(
      await request.readAsJson(),
    );

    final results = await serialize(() {
      return compile(compileRequest);
    });

    if (results.hasOutput) {
      return ok(
        api.CompileDDCResponse(
          result: results.compiledJS!,
          deltaDill: results.deltaDill,
        ).toJson(),
      );
    } else {
      return failure(results.problems.map((p) => p.message).join('\n'));
    }
  }

  Future<Response> handleCompileDDC(Request request, String apiVersion) async {
    return await _handleCompileDDC(
      request,
      apiVersion,
      (compileRequest) => impl.compiler.compileDDC(compileRequest.source),
    );
  }

  Future<Response> handleCompileNewDDC(
    Request request,
    String apiVersion,
  ) async {
    return await _handleCompileDDC(
      request,
      apiVersion,
      (compileRequest) => impl.compiler.compileNewDDC(compileRequest.source),
    );
  }

  Future<Response> handleCompileNewDDCReload(
    Request request,
    String apiVersion,
  ) async {
    return await _handleCompileDDC(
      request,
      apiVersion,
      (compileRequest) => impl.compiler.compileNewDDCReload(
        compileRequest.source,
        compileRequest.deltaDill!,
      ),
    );
  }

  Future<Response> handleComplete(Request request, String apiVersion) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    final sourceRequest = api.SourceRequest.fromJson(
      await request.readAsJson(),
    );

    final result = await serialize(
      () => impl.analyzer.complete(sourceRequest.source, sourceRequest.offset!),
    );

    return ok(result.toJson());
  }

  Future<Response> handleFixes(Request request, String apiVersion) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    final sourceRequest = api.SourceRequest.fromJson(
      await request.readAsJson(),
    );

    final result = await serialize(
      () => impl.analyzer.fixes(sourceRequest.source, sourceRequest.offset!),
    );

    return ok(result.toJson());
  }

  Future<Response> handleFormat(Request request, String apiVersion) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    final sourceRequest = api.SourceRequest.fromJson(
      await request.readAsJson(),
    );

    final result = await serialize(() {
      return impl.analyzer.format(sourceRequest.source, sourceRequest.offset);
    });

    return ok(result.toJson());
  }

  Future<Response> handleDocument(Request request, String apiVersion) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    final sourceRequest = api.SourceRequest.fromJson(
      await request.readAsJson(),
    );

    final result = await serialize(() {
      return impl.analyzer.dartdoc(sourceRequest.source, sourceRequest.offset!);
    });

    return ok(result.toJson());
  }

  Future<Response> suggestFix(Request request, String apiVersion) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    final body = await request.readAsJson();
    final suggestFixRequest = api.SuggestFixRequest.fromJson(body);

    return _streamResponse(
      'suggestFix',
      impl.ai.suggestFix(
        appType: suggestFixRequest.appType,
        message: suggestFixRequest.errorMessage,
        line: suggestFixRequest.line,
        column: suggestFixRequest.column,
        source: suggestFixRequest.source,
        model: _modelOverride(body),
      ),
    );
  }

  Future<Response> generateCode(Request request, String apiVersion) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    final body = await request.readAsJson();
    final generateCodeRequest = api.GenerateCodeRequest.fromJson(body);

    return _streamResponse(
      'generateCode',
      impl.ai.generateCode(
        appType: generateCodeRequest.appType,
        prompt: generateCodeRequest.prompt,
        attachments: generateCodeRequest.attachments,
        model: _modelOverride(body),
        reasoningEffort: _reasoningEffort(body),
      ),
    );
  }

  Future<Response> updateCode(Request request, String apiVersion) async {
    if (apiVersion != api3) return unhandledVersion(apiVersion);

    final body = await request.readAsJson();
    final updateCodeRequest = api.UpdateCodeRequest.fromJson(body);

    return _streamResponse(
      'updateCode',
      impl.ai.updateCode(
        appType: updateCodeRequest.appType,
        prompt: updateCodeRequest.prompt,
        source: updateCodeRequest.source,
        attachments: updateCodeRequest.attachments,
        model: _modelOverride(body),
      ),
    );
  }

  /// Reads the optional per-request `model` override the room service sends to
  /// fail generation over to a different Berget model live. Not part of the
  /// generated `*Request.fromJson` schema (kept out to avoid a codegen cycle),
  /// so it is read leniently here; absent/empty means the boot-time default.
  static String? _modelOverride(Map<String, dynamic> body) {
    final value = body['model'];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// Reads the optional per-request `reasoning_effort` ("low"|"medium"|"high")
  /// — the Berget/OpenAI thinking-mode knob. Read leniently like the model
  /// override (kept out of the codegen schema); absent = the provider default.
  static String? _reasoningEffort(Map<String, dynamic> body) {
    final value = body['reasoning_effort'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<Response> _streamResponse(
    String action,
    Stream<String> inputStream,
  ) async {
    try {
      // NOTE: disabling gzip so that the client gets the data in the same
      // chunks that the LLM is providing it to us. With gzip, the client
      // receives the data all at once at the end of the stream.
      final outputStream = inputStream.transform(utf8.encoder);
      return Response.ok(
        outputStream,
        headers: {
          'Content-Type': 'text/plain; charset=utf-8', // describe our bytes
          'Content-Encoding': 'identity', // disable gzip
        },
        context: {'shelf.io.buffer_output': false}, // disable buffering
      );
    } catch (e, stackTrace) {
      final logger = Logger(action);
      logger.severe('Error during $action operation: $e', e, stackTrace);

      String errorMessage;
      if (e is TimeoutException) {
        errorMessage = 'Operation timed out while processing $action request.';
      } else if (e is FormatException) {
        errorMessage = 'Invalid format in $action request: $e';
      } else if (e is IOException) {
        errorMessage = 'I/O error occurred during $action operation: $e';
      } else {
        errorMessage = 'Failed to process $action request. Error: $e';
      }

      return Response.internalServerError(body: errorMessage);
    }
  }

  void _streamWebsocketResponse(
    WebSocketChannel webSocket,
    JsonRpcRequest request,
    Stream<String> stream,
  ) {
    final timer = Stopwatch()..start();
    stream.listen(
      (data) {
        // Send the stream item as a websocket json-rpc response.
        final response = request.createResultResponse(data);
        final content = jsonEncode(response.toJson());
        webSocket.sink.add(content);

        final time = timer.elapsed;
        final logMsg = _formatLog(request, time, response, content);
        log.info('[ws] $logMsg ...');
      },
      onDone: () {
        // Send a final response with null for the data field.
        final response = request.createResultResponse(null);
        webSocket.sink.add(jsonEncode(response.toJson()));
      },
    );
  }

  Response ok(Map<String, dynamic> json) {
    return Response.ok(
      _jsonEncoder.convert(json),
      encoding: utf8,
      headers: _jsonHeaders,
    );
  }

  Response failure(String message) {
    return Response.badRequest(body: message);
  }

  Response unhandledVersion(String apiVersion) {
    return Response.notFound('unhandled api version: $apiVersion');
  }

  Future<T> serialize<T>(Future<T> Function() fn) {
    return scheduler.schedule(
      ClosureTask(fn, timeoutDuration: const Duration(minutes: 5)),
    );
  }

  api.VersionResponse version() {
    final sdk = impl.sdk;

    final packageVersions = getPackageVersions();

    final packages = [
      for (final MapEntry(key: packageName, value: packageVersion)
          in packageVersions.entries)
        api.PackageInfo(
          name: packageName,
          version: packageVersion,
          supported: isSupportedPackage(packageName),
        ),
    ];

    return api.VersionResponse(
      dartVersion: sdk.dartVersion,
      flutterVersion: sdk.flutterVersion,
      engineVersion: sdk.engineVersion,
      serverRevision: Platform.environment['BUILD_SHA'],
      experiments: sdk.experiments,
      packages: packages,
    );
  }
}

/// Content types for the compiled artifacts, pinned explicitly so nosniff
/// browsers (the fitd26 iframes run with X-Content-Type-Options: nosniff)
/// never refuse a legitimately served script or wasm module. The defaults
/// from package:mime cover these, but pinning removes any dependence on
/// magic-number detection or pub upgrades for the exact extension set the
/// shell and engine load.
final MimeTypeResolver _artifactContentTypes = MimeTypeResolver()
  ..addExtension('js', 'application/javascript; charset=utf-8')
  ..addExtension('wasm', 'application/wasm')
  ..addExtension('map', 'application/json; charset=utf-8')
  ..addExtension('symbols', 'text/plain; charset=utf-8')
  ..addExtension('dill', 'application/octet-stream');

Handler _serveCachedArtifacts(String artifactsPath) {
  final artifactsHandler = createStaticHandler(
    artifactsPath,
    contentTypeResolver: _artifactContentTypes,
  );

  return (Request request) async {
    var response = await artifactsHandler(request);
    if (response.statusCode == 200) {
      response = response.change(
        headers: {
          // Allow Caching for one hour.
          'Cache-Control': 'max-age=3600, public',
        },
      );
    }
    return response;
  };
}

class BadRequest implements Exception {
  final String message;

  BadRequest(this.message);

  @override
  String toString() => message;
}

final JsonEncoder _jsonEncoder = const JsonEncoder.withIndent(' ');

const Map<String, String> _jsonHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Content-Type': jsonContentType,
};

extension RequestExtension on Request {
  Future<Map<String, dynamic>> readAsJson() async {
    final body = await readAsString();
    return body.isNotEmpty
        ? (json.decode(body) as Map<String, dynamic>)
        : <String, dynamic>{};
  }
}

Middleware createCustomCorsHeadersMiddleware() {
  return shelf_cors.createCorsHeadersMiddleware(
    corsHeaders: <String, String>{
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers':
          'Origin, X-Requested-With, Content-Type, Accept, x-goog-api-client',
    },
  );
}

Middleware logRequestsToLogger(DartPadLogger log) {
  return (Handler innerHandler) {
    return (request) {
      final watch = Stopwatch()..start();

      return Future.sync(() => innerHandler(request)).then(
        (response) {
          log.info(_formatMessage(request, watch.elapsed, response: response));

          return response;
        },
        onError: (Object error, StackTrace stackTrace) {
          if (error is HijackException) {
            log.info(_formatMessage(request, watch.elapsed));

            throw error;
          }

          // ignore: only_throw_errors
          throw error;
        },
      );
    };
  };
}

String _formatMessage(
  Request request,
  Duration elapsedTime, {
  Response? response,
  Object? error,
}) {
  final method = request.method;
  final requestedUri = request.requestedUri;
  final statusCode = response?.statusCode;
  final bytes = response?.contentLength;
  final size = ((bytes ?? 0) + 1023) ~/ 1024;

  final ms = elapsedTime.inMilliseconds;
  final query = requestedUri.query == '' ? '' : '?${requestedUri.query}';

  var message =
      '${ms.toString().padLeft(5)}ms ${size.toString().padLeft(4)}k '
      '$statusCode $method ${requestedUri.path}$query';
  if (error != null) {
    message = '$message [$error]';
  }

  return message;
}

String _formatLog(
  JsonRpcRequest request,
  Duration elapsedTime,
  JsonRpcResponse response,
  String? responseContent,
) {
  final method = request.method;
  final statusCode = response.error != null ? 400 : 200;
  final bytes = responseContent?.length;
  final size = ((bytes ?? 0) + 1023) ~/ 1024;

  final ms = elapsedTime.inMilliseconds;

  final message =
      '${ms.toString().padLeft(5)}ms ${size.toString().padLeft(4)}k '
      '$statusCode $method';

  return message;
}
