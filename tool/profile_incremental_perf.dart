import "package:glush/glush.dart";

void main() {
  _benchmarkLargeList();
  _benchmarkExpressionGrammar();
}

void _benchmarkLargeList() {
  print("\n== Benchmark: Large List (Sequence Reuse) ==");
  
  var parser = r"""
    start = item+;
    item = 'a'+ 'b';
  """.toSMParser();

  // Create a large input: 1000 items, each "aaab" (4000 chars)
  var itemText = "aaab";
  var count = 1000;
  var input = itemText * count;
  
  // Initial Parse
  var stopwatch = Stopwatch()..start();
  var state = parser.createParseState(captureTokensAsMarks: true);
  state.positionManager = FingerTree.leaf(input);
  while (state.hasPendingWork) {
    state.processNextToken();
  }
  state.finish();
  stopwatch.stop();
  var initialTime = stopwatch.elapsedMilliseconds;
  print("Initial Parse (4000 chars): ${initialTime}ms");

  // Incremental Parse: Edit at the end
  // Replace the last character 'b' with 'b' (triggers re-parse of the last item)
  stopwatch.reset();
  stopwatch.start();
  var nextState = state.applyEdit(input.length - 1, input.length, "b");
  GlushProfiler.reset();
  GlushProfiler.enabled = true;
  while (nextState.hasPendingWork) {
    nextState.processNextToken();
  }
  nextState.finish();
  stopwatch.stop();
  var incTimeEnd = stopwatch.elapsedMilliseconds;
  var hits = GlushProfiler.snapshot().counters["parser.rule_calls.papa_carlo_fast_forward"] ?? 0;
  print("Incremental Parse (trailing edit): ${incTimeEnd}ms (Cache hits: $hits)");
  print("Speedup: ${(initialTime / (incTimeEnd == 0 ? 1 : incTimeEnd)).toStringAsFixed(1)}x");

  // Incremental Parse: Edit in the middle
  stopwatch.reset();
  stopwatch.start();
  var midPos = input.length ~/ 2;
  // Replace "b" with "a" at middle (invalidates half the tree)
  nextState = state.applyEdit(midPos, midPos + 1, "a"); 
  GlushProfiler.reset();
  while (nextState.hasPendingWork) {
    nextState.processNextToken();
  }
  nextState.finish();
  stopwatch.stop();
  var incTimeMid = stopwatch.elapsedMilliseconds;
  hits = GlushProfiler.snapshot().counters["parser.rule_calls.papa_carlo_fast_forward"] ?? 0;
  print("Incremental Parse (middle edit): ${incTimeMid}ms (Cache hits: $hits)");
}

void _benchmarkExpressionGrammar() {
  print("\n== Benchmark: Expression Grammar (Nested Reuse) ==");
  
  var parser = r"""
    start = expr;
    expr = left:expr '+' right:term | term;
    term = left:term '*' right:atom | atom;
    atom = $num [0-9]+ | '(' expr ')';
  """.toSMParser();

  // Create a deeply nested expression: (1+(1+(...)))
  var depth = 100;
  var input = "${"(" * depth}1${")" * depth}";
  
  // Initial Parse
  var stopwatch = Stopwatch()..start();
  var state = parser.createParseState(captureTokensAsMarks: true);
  state.positionManager = FingerTree.leaf(input);
  while (state.hasPendingWork) {
    state.processNextToken();
  }
  state.finish();
  stopwatch.stop();
  var initialTime = stopwatch.elapsedMilliseconds;
  print("Initial Parse (depth $depth, length ${input.length}): ${initialTime}ms");

  // Incremental Parse: Edit inner number
  var innerPos = depth;
  stopwatch.reset();
  stopwatch.start();
  // Change "1" to "2"
  var nextState = state.applyEdit(innerPos, innerPos + 1, "2"); 
  GlushProfiler.reset();
  GlushProfiler.enabled = true;
  while (nextState.hasPendingWork) {
    nextState.processNextToken();
  }
  nextState.finish();
  stopwatch.stop();
  var incTime = stopwatch.elapsedMilliseconds;
  var hits = GlushProfiler.snapshot().counters["parser.rule_calls.papa_carlo_fast_forward"] ?? 0;
  print("Incremental Parse (inner edit): ${incTime}ms (Cache hits: $hits)");
  print("Speedup: ${(initialTime / (incTime == 0 ? 1 : incTime)).toStringAsFixed(1)}x");
}
