import "package:glush/glush.dart";

/// Demonstrates callable values moving through semantic actions, the DSL, and
/// the higher-order normalization path.
void main() {
  print("=== Callable Values as Data ===");

  var seed = Token.char("a");

  late Rule box;
  var fluentGrammar = Grammar(() {
    late Rule outer;

    box = Rule("box", () {
      return Token.char("b").withAction((_, _) {
        var closure = PatternClosureValue(seed, GuardEnvironment(rule: box));
        return CallArgumentValue.callable(closure);
      });
    });

    outer = Rule("outer", () {
      return (box() >> Token.char("c")).withAction((_, results) {
        var closure = results.first as PatternClosureValue;
        return CallArgumentValue.map({
          "direct": CallArgumentValue.callable(closure),
          "nested": CallArgumentValue.list([
            CallArgumentValue.callable(closure),
            CallArgumentValue.literal("done"),
          ]),
        });
      });
    });

    return outer;
  });

  var fluentParser = SMParser(fluentGrammar);
  var fluentResult = fluentParser.parseAmbiguous("bc", captureTokensAsMarks: true);
  print("Fluent result: $fluentResult");
  if (fluentResult case ParseAmbiguousSuccess(:var forest)) {
    print("Fluent marks: ${forest.allPaths().first}");
  }

  const grammarText = r"""
    start = outer:outer
    outer = box:box tail:tail
    box = value:'b'
    tail = 'c'
  """;

  var dslParser = grammarText.toSMParser();
  var dslResult = dslParser.parseAmbiguous("bc", captureTokensAsMarks: true);
  print("DSL result: $dslResult");
  if (dslResult case ParseAmbiguousSuccess(:var forest)) {
    var tree = forest.allPaths().first;
    print("DSL marks: $tree");

    var boxRule = Rule("box", () => Eps());
    var value = dslParser.evaluateParseTreeWith(
      tree,
      "bc",
      Evaluator<Object?>({
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
        "value": (_) {
          var closure = PatternClosureValue(seed, GuardEnvironment(rule: boxRule));
          return CallArgumentValue.callable(closure);
        },
        "tail": (ctx) => ctx.span,
      }),
    );
    print("DSL value: $value");
  }
}
