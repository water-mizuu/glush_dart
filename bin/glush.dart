// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:io";

import "package:glush/glush.dart";

const grammar = r"""
  S = s:(S) | 's'
""";

final parser = grammar.toSMParser();

void main() {
  // Default behavior: parse and output
  const input = "s";

  // var tracer = FileTracer("another.log");
  var state = parser.createParseState(captureTokensAsMarks: true);
  for (int code in input.codeUnits) {
    state.processToken(code);
  }
  state.finish();

  File("state-machine.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(parser.stateMachine.toDot());

  var paths = state.forest;
  if (!state.accept || paths == null) {
    print("DEBUG: paths is null, returning");
    return;
  }

  print(paths.allMarkPaths().take(5).toList());

  File("another.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(paths.toDot());

  return;
}
