import "dart:math";

import "package:glush/glush.dart";

void main() {
  _measureSingleEdit(captureTokensAsMarks: false);
  _measureSingleEdit(captureTokensAsMarks: true);
}

void _measureSingleEdit({required bool captureTokensAsMarks}) {
  var parser =
      r"""
    start = item+;
    item = 'a'+ 'b';
  """
          .toSMParser();

  var input = "aaab" * 200;
  var warmup = 30;
  var runs = 200;
  var random = Random(42);

  var state = parser.createParseState(captureTokensAsMarks: captureTokensAsMarks);
  state.positionManager = FingerTree.leaf(input);
  while (state.hasPendingWork && state.position < state.positionManager.charLength) {
    state.processNextToken();
  }
  state.finish();

  for (var i = 0; i < warmup; i++) {
    var pos = random.nextInt(input.length - 1);
    var ch = input.codeUnitAt(pos) == 97 ? "b" : "a";
    state = state.applyEdit(pos, pos + 1, ch);
    while (state.hasPendingWork && state.position < state.positionManager.charLength) {
      state.processNextToken();
    }
    state.finish();
  }

  var micros = <int>[];
  for (var i = 0; i < runs; i++) {
    var pos = random.nextInt(input.length - 1);
    var ch = input.codeUnitAt(pos) == 97 ? "b" : "a";

    var sw = Stopwatch()..start();
    state = state.applyEdit(pos, pos + 1, ch);
    while (state.hasPendingWork && state.position < state.positionManager.charLength) {
      state.processNextToken();
    }
    state.finish();
    sw.stop();

    micros.add(sw.elapsedMicroseconds);
  }

  micros.sort();
  var avg = micros.reduce((a, b) => a + b) / micros.length;
  var p50 = micros[micros.length ~/ 2];
  var p95 = micros[(micros.length * 0.95).floor()];
  var p99 = micros[(micros.length * 0.99).floor()];

  print("\n== Single Edit Microbench (captureTokensAsMarks=$captureTokensAsMarks) ==");
  print("runs=$runs avg=${avg.toStringAsFixed(1)}us p50=${p50}us p95=${p95}us p99=${p99}us");
}
