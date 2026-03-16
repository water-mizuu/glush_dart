import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:glush/glush.dart';

/// Spawns an isolate that runs a generated parser from [grammarSource].
/// Returns a [ProcessParser] helper that can repeatedly invoke `parse()` via message passing.
///
/// The isolate listens on a [ReceivePort] and for every message it receives,
/// it calls `parser.parse()` and sends the JSON-encoded result back.
///
/// Callers **must** call [ProcessParser.dispose] when finished.
Future<ProcessParser> spawnProcessParser(
  String grammarSource, {
  String parserName = "GrammarParser",
}) async {
  // Generate the standalone parser code - this includes the SMParser class
  final parserCode = generateStandaloneGrammarDartFile(grammarSource);

  // Build the driver program that listens on a ReceivePort
  // The generated parser code creates a _createGrammarGrammar() function
  final driver = '''
    import "dart:isolate" show ReceivePort, SendPort;

    $parserCode

    Object? _serialize(Object? v) {
      if (v == null) return null;
      if (v is num || v is bool || v is String) return v;
      if (v is List) return v.map(_serialize).toList();
      if (v is Map) return v.map((k, v) => MapEntry(k.toString(), _serialize(v)));
      return v.toString();
    }

    void main(List<String> _, SendPort initPort) {
      var receivePort = ReceivePort();
      initPort.send(receivePort.sendPort);

      // Create the parser using the generated grammar function
      var parser = SMParser(_createGrammarGrammar());

      receivePort.listen((msg) {
        var [replyPort as SendPort, input as String] = msg as List;
        try {
          var result = parser.parse(input);

          if (result is ParseSuccess) {
            replyPort.send(["ok", _serialize(result.result.marks)]);
          }
        } catch (e, st) {
          replyPort.send(["error", e.toString(), st.toString()]);
        }
      });
    }
    ''';

  // Write the driver code to the temporary file
  final uri = Uri.dataFromString(
    driver,
    mimeType: "application/dart",
    encoding: utf8,
    base64: true,
  );

  // Set up receive port for initialization
  final initPort = ReceivePort();
  final onError = ReceivePort();

  // Spawn the isolate
  final isolate = await Isolate.spawnUri(
    uri,
    [],
    initPort.sendPort,
    onError: onError.sendPort,
  );

  // Get the parser's send port
  final parserSendPort = await initPort.first as SendPort;

  // Listen for errors from the isolate
  onError.listen((data) {
    throw StateError("Isolate error: $data");
  });

  return ProcessParser._(isolate, parserSendPort, initPort, onError);
}

/// Helper class for managing a parser isolate.
class ProcessParser {
  late final StreamSubscription<dynamic> _subscription;
  final Isolate _isolate;
  final SendPort _parserSendPort;
  final ReceivePort _initPort;
  final ReceivePort _onError;
  int _requestId = 0;
  final Map<int, Completer<List<dynamic>>> _pendingRequests = {};

  ProcessParser._(
    this._isolate,
    this._parserSendPort,
    this._initPort,
    this._onError,
  ) {
    // We don't need to listen to initPort or onError anymore after setup
  }

  /// Parses the given [input] string and returns the result.
  /// Returns a list: ["ok", result] on success, ["fail", errors] on parse failure,
  /// or ["error", message, stackTrace] on exception.
  Future<List<dynamic>> parse(String input) async {
    final responsePort = ReceivePort();
    final requestId = _requestId++;

    final completer = Completer<List<dynamic>>();
    _pendingRequests[requestId] = completer;

    // Listen for this specific response
    _subscription = responsePort.listen((response) {
      if (_pendingRequests.containsKey(requestId)) {
        final completer = _pendingRequests.remove(requestId)!;
        if (response is List<dynamic>) {
          String first = response[0] as String;

          if (first == "ok") {
            List<String> second = (response[1] as List).whereType<String>().toList();

            completer.complete(["ok", second]);
          }
        }
      }
      responsePort.close();
    });

    // Send the parse request with the response port
    _parserSendPort.send([responsePort.sendPort, input]);

    return completer.future;
  }

  /// Stops the parser isolate and cleans up temporary files.
  Future<void> dispose() async {
    _isolate.kill();
    _initPort.close();
    _onError.close();
    _subscription.cancel();
  }
}
