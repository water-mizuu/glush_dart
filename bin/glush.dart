// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:io";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart" show FileTracer;

// final grammar = Grammar(() {
//   late Rule s;
//   s = Rule("S", () {
//     return Label("1", Token.char("s")) | // s
//         Label("2", s() >> s()) |
//         Label("3", s() >> s() >> s()) |
//         Label("4", s() >> s() >> s() >> s());
//   });
//   return s;
// });
// final parser = SMParserMini(grammar);

const grammar = r"""
S = $2 &S S [s] | $1 [s]
""";

final parser = grammar.toSMParser();

void main() async {
  const input = "sss";

  var tracer = FileTracer("another.log");
  var state = parser.createParseState(isSupportingAmbiguity: true, tracer: tracer);
  for (int code in input.codeUnits) {
    state.processToken(code);
  }
  state.finish();

  var paths = state.lastStep?.acceptedContexts.values
      .fold(const GlushList<Mark>.empty(), GlushList<Mark>.branched);

  if (paths == null) {
    return;
  }

  print(paths.allPaths().map((v) => v.evaluateStructure()).join("\n"));

  File("another.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(paths.toDot());

  File("state-machine.dot")
    ..createSync(recursive: true)
    ..writeAsStringSync(parser.stateMachine.toDot());
}
