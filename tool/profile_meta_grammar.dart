import "package:glush/glush.dart";
import "package:glush/src/compiler/metagrammar_evaluator.dart";
import "package:glush/src/parser/bytecode/bytecode_parser.dart";

T measure<T>(String label, int n, T Function() fn) {
  T? last;
  var total = 0;
  for (var i = 0; i < n; i++) {
    var sw = Stopwatch()..start();
    last = fn();
    sw.stop();
    total += sw.elapsedMicroseconds;
  }
  print("$label avg_ms=${(total / n / 1000).toStringAsFixed(3)} n=$n");
  return last as T;
}

void main() {
  measure("GrammarFileParser.parse(meta)", 30, () => GrammarFileParser(metaGrammarString).parse());
  var ast = measure(
    "GrammarFileParser.parse(meta) once for compile",
    1,
    () => GrammarFileParser(metaGrammarString).parse(),
  );
  measure(
    "GrammarFileCompiler.compile(meta)",
    30,
    () => GrammarFileCompiler(ast).compile(startRuleName: "full"),
  );
  var smParser = measure("compile+SMParser ctor", 10, () {
    var g = GrammarFileCompiler(
      GrammarFileParser(metaGrammarString).parse(),
    ).compile(startRuleName: "full");
    return SMParser(g);
  });

  measure("SM metaParser.parse(simple)", 50, () => smParser.parse("rule = 'a'\n"));
  measure("SM metaParser.parse(self)", 30, () {
    var result = smParser.parse(metaGrammarString);
    if (result is! ParseSuccess && result is! ParseAmbiguousSuccess) {
      throw Exception("Parse failed: $result");
    }
    return result;
  });
  measure("SM metaParser.parse(ambiguous)", 30, () {
    var result = smParser.parseAmbiguous(metaGrammarString);
    if (result is! ParseSuccess && result is! ParseAmbiguousSuccess) {
      throw Exception("Parse failed: $result");
    }
    return result.ambiguousSuccess()!.forest.allMarkPaths().first;
  });

  var bcParser = measure("compile + BCParser ctor", 10, () {
    var g = GrammarFileCompiler(
      GrammarFileParser(metaGrammarString).parse(),
    ).compile(startRuleName: "full");
    return BCParser(g);
  });

  measure("BC metaParser.parse(simple)", 50, () => bcParser.parse("rule = 'a'\n"));
  measure("BC metaParser.parse(self)", 30, () {
    var result = bcParser.parse(metaGrammarString);
    if (result is! ParseSuccess && result is! ParseAmbiguousSuccess) {
      throw Exception("Parse failed: $result");
    }
    return result;
  });
  measure("BC metaParser.parse(ambiguous)", 30, () {
    var result = bcParser.parseAmbiguous(metaGrammarString);
    if (result is! ParseSuccess && result is! ParseAmbiguousSuccess) {
      throw Exception("Parse failed: $result");
    }
    return result.ambiguousSuccess()!.forest.allMarkPaths().first;
  });
}
