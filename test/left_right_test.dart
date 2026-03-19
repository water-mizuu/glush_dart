import 'package:glush/glush.dart';

void main() {
  print("=== RIGHT RECURSIVE ===");
  testGrammar(false);
  print("\n=== LEFT RECURSIVE ===");
  testGrammar(true);
}

void testGrammar(bool leftRecursive) {
  late Rule S;
  final g = Grammar(() {
    S = Rule(
      'S',
      () =>
          Pattern.char('s') |
          (leftRecursive
              ? (S.call() >> Pattern.char('+') >> Pattern.char('s'))
              : (Pattern.char('s') >> Pattern.char('+') >> S.call())),
    );
    return S;
  });

  final parser = SMParser(g);

  for (final n in [1, 10, 50, 100]) {
    final input = "s" + "+s" * n;
    final sw = Stopwatch()..start();
    final bsrResult = parser.parseToBsr(input);
    if (bsrResult is BsrParseSuccess) {
      final parseTime = sw.elapsedMilliseconds;
      sw.reset();

      final bsr = bsrResult.bsrSet;
      final startRule = parser.stateMachine.grammar.startCall.rule;
      final nm = ForestNodeManager();

      final root = bsr.buildSppf(g, startRule, input, nm);
      final buildTime = sw.elapsedMilliseconds;

      if (root != null) {
        final forest = ParseForest(nm, root, bsrResult.marks);
        print(
          "n=$n: SUCCESS, nodes: ${forest.countNodes()}, parse: ${parseTime}ms, build: ${buildTime}ms",
        );
      } else {
        print("n=$n: FAILED (root is null)");
      }
    } else {
      print("n=$n: PARSE FAILED");
    }
  }
}
