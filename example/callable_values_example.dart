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
  var fluentForest = fluentParser.parseWithForest("bc");
  print("Fluent forest: $fluentForest");
  if (fluentForest case ParseForestSuccess(:var forest)) {
    var tree = forest.extract().first;
    print("Fluent tree: ${tree.toTreeString()}");
    var value = fluentParser.evaluateParseTree(tree, "bc");
    print("Fluent value: $value");
  }

  const grammarText = r"""
    start = outer:outer
    outer = box:box tail:tail
    box = value:'b'
    tail = 'c'
  """;

  var dslParser = grammarText.toSMParser();
  var dslForest = dslParser.parseWithForest("bc");
  print("DSL forest: $dslForest");
  if (dslForest case ParseForestSuccess(:var forest)) {
    var tree = forest.extract().first;
    print("DSL tree: ${tree.toTreeString()}");

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
