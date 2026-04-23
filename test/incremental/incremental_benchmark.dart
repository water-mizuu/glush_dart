import "package:glush/glush.dart";

void main() {
  var parser =
      r"""
    S = $expr expr;
    expr = $add left:expr right:plus_term | term;
    plus_term = $concat '+' term;
    term = $mul left:term '*' right:atom | atom;
    atom = $num [0-9]+;
  """
          .toSMParser();

  print("=== Glush Incremental Parsing Benchmark ===");

  // 1. Prepare large input: 100 additions
  var buffer = StringBuffer("1");
  for (var i = 0; i < 100; i++) {
    buffer.write("+${i % 10}");
  }
  var input = buffer.toString();
  print("Input size: ${input.length} characters");

  // 2. Cold Parse
  GlushProfiler.enabled = true;
  GlushProfiler.reset();

  var coldWatch = Stopwatch()..start();
  var state = parser.createParseState(captureTokensAsMarks: true);
  state.positionManager = FingerTree.leaf(input);
  while (state.hasPendingWork && state.position < state.positionManager.charLength) {
    state.processNextToken();
  }
  state.finish();
  coldWatch.stop();

  print("\nCOLD PARSE:");
  print("Time: ${coldWatch.elapsedMicroseconds} µs");
  print("Per char: ${(coldWatch.elapsedMicroseconds / input.length).toStringAsFixed(2)} µs");
  print("Accept: ${state.accept}");

  // 3. Incremental Parse: Edit at the end
  // Change the last character
  GlushProfiler.reset();
  var endEditWatch = Stopwatch()..start();
  var endEditState = state.applyEdit(input.length - 1, input.length, "9");
  while (endEditState.hasPendingWork &&
      endEditState.position < endEditState.positionManager.charLength) {
    endEditState.processNextToken();
  }
  endEditState.finish();
  endEditWatch.stop();

  print("\nINCREMENTAL PARSE (Edit at end):");
  print("Time: ${endEditWatch.elapsedMicroseconds} µs");
  print("Accept: ${endEditState.accept}");
  var speedup = coldWatch.elapsedMicroseconds / endEditWatch.elapsedMicroseconds;
  print("Speedup: ${speedup.toStringAsFixed(1)}x");

  var snapshot = GlushProfiler.snapshot();
  var jumpCount = snapshot.counters["parser.incremental.jump"] ?? 0;
  print("Papa Carlo Jumps: $jumpCount");

  // 4. Incremental Parse: Edit in the middle
  GlushProfiler.reset();
  var midEditWatch = Stopwatch()..start();
  var midEditState = state.applyEdit(100, 101, "5");
  while (midEditState.hasPendingWork &&
      midEditState.position < midEditState.positionManager.charLength) {
    midEditState.processNextToken();
  }
  midEditState.finish();
  midEditWatch.stop();

  print("\nINCREMENTAL PARSE (Edit in middle):");
  print("Time: ${midEditWatch.elapsedMicroseconds} µs");
  print("Accept: ${midEditState.accept}");
  speedup = coldWatch.elapsedMicroseconds / midEditWatch.elapsedMicroseconds;
  print("Speedup: ${speedup.toStringAsFixed(1)}x");

  snapshot = GlushProfiler.snapshot();
  jumpCount = snapshot.counters["parser.incremental.jump"] ?? 0;
  print("Papa Carlo Jumps: $jumpCount");

  // 5. Incremental Parse: Edit at the beginning
  GlushProfiler.enabled = false;
  GlushProfiler.reset();
  var startEditWatch = Stopwatch()..start();
  var startEditState = state.applyEdit(0, 1, "2");
  while (startEditState.hasPendingWork &&
      startEditState.position < startEditState.positionManager.charLength) {
    startEditState.processNextToken();
  }
  startEditState.finish();
  startEditWatch.stop();

  print("\nINCREMENTAL PARSE (Edit at start):");
  print("Time: ${startEditWatch.elapsedMicroseconds} µs");
  print("Accept: ${startEditState.accept}");
  speedup = coldWatch.elapsedMicroseconds / startEditWatch.elapsedMicroseconds;
  print("Speedup: ${speedup.toStringAsFixed(1)}x");

  snapshot = GlushProfiler.snapshot();
  jumpCount = snapshot.counters["parser.incremental.jump"] ?? 0;
  print("Papa Carlo Jumps: $jumpCount");
  print("\n--- Start Edit Profile ---");
  print(snapshot.report());

  // Verify forest integrity
  var paths = startEditState.forest!.allMarkPaths().toList();
  var structure = paths.first
      .evaluateStructure(startEditState.positionManager.toString())
      .toString();
  if (!structure.contains("num")) {
    print("ERROR: Forest integrity failed (missing 'num')");
  } else {
    print("Forest Integrity: OK (Structure evaluated)");
  }
}
