import 'dart:async';
import 'dart:isolate';

/// Helper class for managing a parser isolate.
class ProcessParser {
  late final StreamSubscription<Object?> _subscription;
  final Isolate _isolate;
  final SendPort _parserSendPort;
  final ReceivePort _initPort;
  final ReceivePort _onError;
  int _requestId = 0;
  final Map<int, Completer<List<Object?>>> _pendingRequests = {};

  ProcessParser._(this._isolate, this._parserSendPort, this._initPort, this._onError) {
    // We don't need to listen to initPort or onError anymore after setup
  }

  /// Parses the given [input] string and returns the result.
  /// Returns a list: ["ok", result] on success, ["fail", errors] on parse failure,
  /// or ["error", message, stackTrace] on exception.
  Future<List<Object?>> parse(String input) async {
    final responsePort = ReceivePort();
    final requestId = _requestId++;

    final completer = Completer<List<Object?>>();
    _pendingRequests[requestId] = completer;

    // Listen for this specific response
    _subscription = responsePort.listen((response) {
      if (_pendingRequests.containsKey(requestId)) {
        final completer = _pendingRequests.remove(requestId)!;
        if (response is List<Object?>) {
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
