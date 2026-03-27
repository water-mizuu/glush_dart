import "dart:math" as math;

import "package:glush/glush.dart";

typedef Runner = void Function();

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
  _measure("parseWithForest", 120, () => parser.parseWithForest("[aa]a"));
  _measure("parseToBsr", 120, () => parser.parseToBsr("[aa]a"));
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
  _measure("parseWithForest", 120, () => parser.parseWithForest("[aa]"));
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
  var forestOutcome = _measure("parseWithForest_once", 120, () => parser.parseWithForest("alpha:beta"));
  var forest = (forestOutcome as ParseForestSuccess).forest;
  var tree = forest.extract().first;
  var evaluator = Evaluator<Object?>({
    "full": (ctx) => ctx<Object?>("file"),
    "rule": (ctx) => (ctx<String>("name"), ctx<Object?>("body")),
    "name": (ctx) => ctx.span,
    "ws": (ctx) => ctx.span,
  });
  _measure("forest.extract.first", 120, () => forest.extract().first);
  _measure("evaluateParseTreeWith", 200, () => parser.evaluateParseTreeWith(tree, "alpha:beta", evaluator));

  const callableGrammarText = r"""
    start = outer:outer
    outer = box:box tail:tail
    box = value:'b'
    tail = 'c'
  """;

  var callableParser = _measure("compile_callable", 50, () => callableGrammarText.toSMParser());
  var callableForestOutcome = _measure(
    "parseWithForest_callable_once",
    120,
    () => callableParser.parseWithForest("bc"),
  );
  var callableTree = (callableForestOutcome as ParseForestSuccess).forest.extract().first;
  var boxRule = Rule("box", () => Eps());
  var seed = Token.char("a");
  var callableEvaluator = Evaluator<Object?>({
    "start": (ctx) => ctx<Object?>("outer"),
    "outer": (ctx) {
      var closure = ctx<Object?>("box")! as PatternClosureValue;
      return CallArgumentValue.map({
        "direct": CallArgumentValue.callable(closure),
        "nested": CallArgumentValue.list([
          CallArgumentValue.callable(closure),
          CallArgumentValue.literal(ctx<String>("tail")),
        ]),
      });
    },
    "value": (ctx) {
      var closure = PatternClosureValue(seed, GuardEnvironment(rule: boxRule));
      return CallArgumentValue.callable(closure);
    },
    "tail": (ctx) => ctx.span,
  });
  _measure("evaluate_callable_tree", 200, () {
    callableParser.evaluateParseTreeWith(callableTree, "bc", callableEvaluator);
  });
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
