import "dart:math";

import "package:glush/glush.dart";

void main() {
  var grammarText = r"""
    S = $list block+;
    block = $block '{' expr+ '}';
    expr = $add left:expr '+' right:term | term;
    term = $mul left:term '*' right:atom | atom;
    atom = $num [0-9]+;
  """;
  var parser = grammarText.toSMParser();

  // 1. Generate 1MB input (blocks of expressions)
  print("Generating 1MB input...");
  var buffer = StringBuffer();
  var random = Random(42);
  for (var b = 0; b < 1000; b++) {
    buffer.write("{");
    for (var i = 0; i < 50; i++) {
      buffer.write("${random.nextInt(10)}*${random.nextInt(10)}+");
    }
    buffer.write("1}");
  }
  var input = buffer.toString();
  print("Input size: ${input.length} characters");

  // 2. Initial Cold Parse
  var coldWatch = Stopwatch()..start();
  var state = parser.createParseState();
  state.positionManager = FingerTree.leaf(input);
  while (state.hasPendingWork && state.position < state.positionManager.charLength) {
    state.processNextToken();
  }
  state.finish();
  coldWatch.stop();
  print("Cold Parse: ${coldWatch.elapsedMilliseconds} ms");

  // 3. Sequential Edits at random positions
  print("\nRunning 100 sequential edits...");
  GlushProfiler.enabled = true;
  GlushProfiler.reset();
  var totalMicros = 0;
  var editCount = 100;

  for (var i = 0; i < editCount; i++) {
    var pos = random.nextInt(input.length - 10);
    var editWatch = Stopwatch()..start();

    // Apply edit
    var newState = state.applyEdit(pos, pos + 1, random.nextInt(10).toString());

    // Re-parse
    while (newState.hasPendingWork && newState.position < newState.positionManager.charLength) {
      newState.processNextToken();
    }
    newState.finish();
    editWatch.stop();

    totalMicros += editWatch.elapsedMicroseconds;
    state = newState; // Sequential

    if (i % 10 == 0) {
      print("Edit $i: ${editWatch.elapsedMicroseconds} µs");
    }
  }

  print("\nAverage Incremental Parse: ${totalMicros / editCount} µs");
  print("Throughput: ${1000000 / (totalMicros / editCount)} edits/sec");

  print("\nProfiler Report:");
  print(GlushProfiler.snapshot().report());
}
