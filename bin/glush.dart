// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart" show FileTracer;

const grammar = r"""
S = $2  S  S
  | $1 's'
""";

final parser = grammar.toSMParser();

void main() {
  // Default behavior: parse and output
  const input = "sss";

  var tracer = FileTracer("another.log");
  var state = parser.createParseState(isSupportingAmbiguity: true, tracer: tracer);
  for (int code in input.codeUnits) {
    state.processToken(code);
  }
  state.finish();

  var paths = state.forest;
  if (!state.accept || paths == null) {
    print("DEBUG: paths is null, returning");
    return;
  }

  var evaluator = Evaluator<String>({"S.2": (ctx) => "(${ctx()}${ctx()})", "S.1": (ctx) => "s"});

  for (var (i, path) in paths.allMarkPaths().indexed) {
    var tree = path.evaluateStructure();
    var evaluated = evaluator.evaluate(tree);

    print("$i: $evaluated");
  }

  File("another.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(paths.toDot());

  File("state-machine.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(parser.stateMachine.toDot());

  return;
}
