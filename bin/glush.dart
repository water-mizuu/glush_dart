// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart";

const grammar = """
  S = [0-9]+ [0-9]
""";
final parser = grammar.toSMParser();

void main() {
  // Default behavior: parse and output
  const input = "1230";

  var tracer = FileTracer("another.log");
  var state = parser.createParseState(captureTokensAsMarks: true, tracer: tracer);
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
