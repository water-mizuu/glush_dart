import "package:glush/glush.dart";
import "package:glush/src/compiler/metagrammar_evaluator.dart";
import "package:glush/src/parser/bytecode/bytecode_parser.dart";

void main() {
  var grammarSource = metaGrammarString;
  var grammar = grammarSource.toGrammar();

  var smParser = SMParser(grammar);
  var bcParser = BCParser(grammar);

  var input = grammarSource; // Self-parse benchmark

  print("\n--- Validation ---");
  var res1 = smParser.parse(input);
  var res2 = bcParser.parse(input);

  print("SMParser success: ${res1 is ParseSuccess}");
  print("BytecodeParser success: ${res2 is ParseSuccess}");

  if (res2 is ParseError) {
    print("BC Error at: ${res2.position}");
  }

  print("\n--- Warm-up ---");
  for (int i = 0; i < 3; i++) {
    smParser.parse(input);
    bcParser.parse(input);
  }

  print("\n--- Benchmarking ---");

  var smTotal = 0;
  var bcTotal = 0;
  var iterations = 5;

  for (var i = 0; i < iterations; i++) {
    var sw = Stopwatch()..start();
    smParser.parse(input);
    sw.stop();
    smTotal += sw.elapsedMilliseconds;

    sw.reset();
    sw.start();
    bcParser.parse(input);
    sw.stop();
    bcTotal += sw.elapsedMilliseconds;

    print("Iteration ${i + 1}: SM=${smTotal ~/ (i + 1)}ms, BC=${bcTotal ~/ (i + 1)}ms");
  }

  print("\nSMParser average: ${smTotal / iterations}ms");
  print("BytecodeParser average: ${bcTotal / iterations}ms");
  if (smTotal > 0) {
    print("Improvement: ${((smTotal - bcTotal) / smTotal * 100).toStringAsFixed(1)}%");
  }
}
