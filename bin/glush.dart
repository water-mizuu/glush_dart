// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart" show FileTracer;

const grammar = r"""
S = $3 &(S S S) S S S 
  | $2 &(S S) S S
  | $1 's'
""";

final parser = grammar.toSMParser();

void main(List<String> args) async {
  // Default behavior: parse and output
  const input = "sssss";

  var tracer = FileTracer("another.log");
  var state = parser.createParseState(isSupportingAmbiguity: true, tracer: tracer);
  for (int code in input.codeUnits) {
    state.processToken(code);
  }
  state.finish();

  var paths = state.lastStep?.acceptedContexts.values.fold(
    const GlushList<Mark>.empty(),
    GlushList<Mark>.branched,
  );

  print("DEBUG: paths = $paths, isNull = ${paths == null}");
  print("DEBUG: accepted contexts = ${state.lastStep?.acceptedContexts}");

  if (!state.accept || paths == null) {
    print("DEBUG: paths is null, returning");
    return;
  }

  var evaluator = Evaluator<String>({
    "S.3": (ctx) => "(${ctx.next()}${ctx.next()}${ctx.next()})",
    "S.2": (ctx) => "(${ctx.next()}${ctx.next()})",
    "S.1": (ctx) => "s",
  });

  for (var (i, path) in paths.allPaths().indexed) {
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
