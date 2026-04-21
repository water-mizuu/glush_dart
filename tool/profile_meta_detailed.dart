import "package:glush/glush.dart";
import "package:glush/src/compiler/metagrammar_evaluator.dart";

void main() {
  print("Compiling meta-grammar...");
  var grammar = GrammarFileCompiler(
    GrammarFileParser(metaGrammarString).parse(),
  ).compile(startRuleName: "full");

  print("Creating SMParser...");
  var parser = SMParser(grammar);

  print("\nParsing simple input (warm-up)...");
  GlushProfiler.enabled = true;
  GlushProfiler.reset();
  var result1 = parser.parse("rule = 'a'\n");
  print("Result: ${result1.runtimeType}");
  print(GlushProfiler.snapshot().report());

  print("\n=== Parsing meta-grammar (MAIN BENCHMARK) ===");
  GlushProfiler.enabled = true;
  GlushProfiler.reset();
  var sw = Stopwatch()..start();
  var result2 = parser.parse(metaGrammarString);
  sw.stop();
  print("Parse result: ${result2.runtimeType}");
  print("Time: ${sw.elapsedMilliseconds} ms");
  print(GlushProfiler.snapshot().report());
}
