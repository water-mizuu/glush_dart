// ignore_for_file: strict_raw_type, unreachable_from_main

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
S = $4  S  S  S  S
  | $3  S  S  S
  | $2  S  S
  | $1 "s"
""";

final parser = grammar.toSMParser();

void main() async {
  const input = "ssss";

  var tracer = FileTracer("another.log");
  var state = parser.createParseState(isSupportingAmbiguity: true, tracer: tracer);
  for (int code in input.codeUnits) {
    state.processToken(code);
  }
  state.finish();

  var eval = Evaluator<Object>({
    "S.2": (ctx) => "(${ctx.next()}${ctx.next()})",
    "S.1": (ctx) => "${ctx.next()}",
  });

  var paths = state.lastStep?.acceptedContexts
      .map((v) => v.marks)
      .fold(const GlushList<Mark>.empty(), (a, b) => GlushList<Mark>.branched([a, b]));

  if (paths == null) {
    return;
  }

  var result = parser.parseAmbiguous(input);
  var derivations = result.ambiguousSuccess()!.forest.toList();

  print(derivations.length);
  print(paths.derivationCount);
  for (var path in paths.allPaths()) {
    print(path);
  }
}
