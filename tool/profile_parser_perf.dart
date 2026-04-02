import "dart:math" as math;

import "package:glush/glush.dart";

void main() {
  _profileDataDrivenParameters();
  _profileDataDrivenRules();
  _profileForestEvaluator();
}

void _profileDataDrivenParameters() {
  const grammarText = r"""
    start = wrapper(content: pair(piece: atom)) atom

    wrapper(content) = '[' content ']'
    pair(piece) = piece piece
    atom = 'a' | 'b'
  """;

  _printHeader("data_driven_parameters");
  var parser = _measure("compile", 50, () => grammarText.toSMParser());
  _measure("recognize", 400, () => parser.recognize("[aa]a"));
  _measure("parse", 300, () => parser.parse("[aa]a"));
  _measure("parseAmbiguous", 150, () => parser.parseAmbiguous("[aa]a"));
}

void _profileDataDrivenRules() {
  const grammarText = r"""
    start = left | right

    left = leftMark:outer(inner: pair(piece: atom))
    right = rightMark:outer(inner: altPair(piece: atom))

    outer(inner) = '[' inner ']'
    pair(piece) = piece piece
    altPair(piece) = piece piece
    atom = 'a'
  """;

  _printHeader("data_driven_rules");
  var parser = _measure("compile", 50, () => grammarText.toSMParser());
  _measure("recognize", 400, () => parser.recognize("[aa]"));
  _measure("parse", 300, () => parser.parse("[aa]"));
  _measure("parseAmbiguous", 120, () => parser.parseAmbiguous("[aa]", captureTokensAsMarks: true));
}

void _profileForestEvaluator() {
  const grammarText = r'''
    start = $full file:rule;
    rule = $rule name:name _ ":" _ body:name;
    name = [a-z]+;
    _ = $ws [ \t]*;
  ''';

  _printHeader("forest_evaluator");
  var parser = _measure("compile", 50, () => grammarText.toSMParser());
  _measure(
    "parseAmbiguous_once",
    120,
    () => parser.parseAmbiguous("alpha:beta", captureTokensAsMarks: true),
  );
}

T _measure<T>(String label, int iterations, T Function() fn) {
  T? last;
  var samples = <int>[];
  for (var i = 0; i < iterations; i++) {
    var watch = Stopwatch()..start();
    last = fn();
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }

  samples.sort();
  var total = samples.fold<int>(0, (a, b) => a + b);
  print(
    "$label: avg=${_fmt(total / iterations)}ms "
    "p50=${_fmt(samples[samples.length ~/ 2].toDouble())}ms "
    "p95=${_fmt(samples[math.max(0, ((samples.length * 95) ~/ 100) - 1)].toDouble())}ms "
    "max=${_fmt(samples.last.toDouble())}ms "
    "n=$iterations",
  );
  return last as T;
}

String _fmt(double micros) => (micros / 1000).toStringAsFixed(3);

void _printHeader(String title) {
  print("");
  print("== $title ==");
}
