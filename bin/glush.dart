// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart";

// final parser = grammar.toSMParser();

final grammar = Grammar(() {
  late Rule S;
  S = Rule("ASDF", () => (Not(Token.charRange("0", "9")) >> Token.any()).plus());

  return S;
});
final parser = SMParser(grammar);

void main() {
  // Default behavior: parse and output
  const input = "abc";

  var tracer = FileTracer("another.log");
  var state = parser.createParseState(captureTokensAsMarks: true, tracer: tracer);
  for (int code in input.codeUnits) {
    state.processToken(code);
  }
  state.finish();

  File("state-machine.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(parser.stateMachine.toDot());

  print(state.accept);
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
