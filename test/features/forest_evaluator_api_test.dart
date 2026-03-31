import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Forest Evaluator API", () {
    test("evaluateParseTreeWith supports mark handlers and labels", () {
      var parser =
          r'''
            start = $full file:rule;
            rule = $rule name:name _ ":" _ body:name;
            name = [a-z]+;
            _ = $ws [ \t]*;
          '''
              .toSMParser();

      var forestOutcome = parser.parseWithForest("alpha:beta");
      expect(forestOutcome, isA<ParseForestSuccess>());
      var tree = (forestOutcome as ParseForestSuccess).forest.extract().first;

      var evaluator = Evaluator<Object?>({
        "full": (ctx) => ctx<Object?>("file"),
        "rule": (ctx) => (ctx<String>("name"), ctx<Object?>("body")),
        "name": (ctx) => ctx.span,
        "ws": (ctx) => ctx.span,
      });

      var value = parser.evaluateParseTreeWith(tree, "alpha:beta", evaluator);
      expect(value, equals(("alpha", "beta")));
    });

    test("all collects repeated labels as a list", () {
      var evaluator = Evaluator<Object?>({
        "items": (ctx) => ctx.all<String>("item"),
        "item": (ctx) => ctx.span,
      });

      var tree = ParseResult([
        (
          "items",
          ParseResult([
            ("item", ParseResult([], "a")),
            ("item", ParseResult([], "a")),
            ("item", ParseResult([], "a")),
          ], "aaa"),
        ),
      ], "aaa");

      expect(evaluator.evaluate(tree), equals(["a", "a", "a"]));
    });

    test("all returns an empty list when the label is absent", () {
      var evaluator = Evaluator<Object?>({"items": (ctx) => ctx.all<String>("item")});

      var tree = ParseResult([("items", ParseResult([], ""))], "");

      expect(evaluator.evaluate(tree), equals(<String>[]));
    });

    test("extractParseTreeRawMarks includes label and named marks", () {
      var parser =
          r"""
            start = $full file:item;
            item = $item left:name;
            name = [a-z]+;
          """
              .toSMParser();

      var forestOutcome = parser.parseWithForest("abc");
      expect(forestOutcome, isA<ParseForestSuccess>());
      var tree = (forestOutcome as ParseForestSuccess).forest.extract().first;

      var marks = parser.extractParseTreeRawMarks(tree, "abc");
      expect(marks.any((m) => m is LabelStartMark && m.name == "start.full"), isTrue);
      expect(marks.any((m) => m is LabelEndMark && m.name == "start.full"), isTrue);
      expect(marks.any((m) => m is LabelStartMark && m.name == "item.item"), isTrue);
      expect(marks.any((m) => m is LabelEndMark && m.name == "item.item"), isTrue);
      expect(marks.any((m) => m is LabelStartMark && m.name == "file"), isTrue);
      expect(marks.any((m) => m is LabelEndMark && m.name == "file"), isTrue);
      expect(marks.any((m) => m is LabelStartMark && m.name == "left"), isTrue);
      expect(marks.any((m) => m is LabelEndMark && m.name == "left"), isTrue);

      var fileEnd = marks.whereType<LabelEndMark>().firstWhere((m) => m.name == "file");
      var itemEnd = marks.whereType<LabelEndMark>().firstWhere((m) => m.name == "item.item");
      var leftEnd = marks.whereType<LabelEndMark>().firstWhere((m) => m.name == "left");

      expect(fileEnd.position, equals(0));
      expect(itemEnd.position, equals(0));
      expect(leftEnd.position, equals(0));
    });

    test("evaluateChildren skips unhandled siblings until it finds a handler", () {
      var tree = ParseResult([
        ("ws", ParseResult([], " ")),
        ("value", ParseResult([], "beta")),
      ], " beta");

      var evaluator = Evaluator<String>({"value": (ctx) => ctx.span});

      expect(evaluator.evaluate(tree), equals("beta"));
    });

    test("fluent semantic actions can return callable values as data", () {
      late Rule box;
      late Rule outer;
      var seed = Token.char("a");

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

      var parser = SMParser(Grammar(() => outer));
      var forestOutcome = parser.parseWithForest("bc");
      expect(forestOutcome, isA<ParseForestSuccess>());
      var tree = (forestOutcome as ParseForestSuccess).forest.extract().first;

      var value = parser.evaluateParseTree(tree, "bc");
      expect(value, isA<Map<String, Object?>>());

      var map = value! as Map<String, Object?>;
      expect(map["direct"], isA<PatternClosureValue>());
      expect(map["nested"], isA<List<Object?>>());

      var direct = map["direct"]! as PatternClosureValue;
      var nested = map["nested"]! as List<Object?>;
      expect(direct.materialize(GuardEnvironment(rule: box)), same(seed));
      expect(nested.first, isA<PatternClosureValue>());
      expect(nested[1], equals("done"));
    });

    test("String DSL semantic handlers can return callable values as data", () {
      const grammarText = r"""
        start = outer:outer
        outer = box:box tail:tail
        box = value:'b'
        tail = 'c'
      """;

      var parser = grammarText.toSMParser();
      var boxRule = Rule("box", () => Eps());
      var seed = Token.char("a");

      var forestOutcome = parser.parseWithForest("bc");
      expect(forestOutcome, isA<ParseForestSuccess>());
      var tree = (forestOutcome as ParseForestSuccess).forest.extract().first;

      var evaluator = Evaluator<Object?>({
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

      var value = parser.evaluateParseTreeWith(tree, "bc", evaluator);
      expect(value, isA<Map<String, Object?>>());

      var map = value! as Map<String, Object?>;
      expect(map["direct"], isA<PatternClosureValue>());
      expect(map["nested"], isA<List<Object?>>());

      var direct = map["direct"]! as PatternClosureValue;
      var nested = map["nested"]! as List<Object?>;
      expect(direct.materialize(GuardEnvironment(rule: boxRule)), same(seed));
      expect(nested.first, isA<PatternClosureValue>());
      expect(nested[1], equals("c"));
    });

    test("higher-order calls preserve marks as a structured tree", () {
      const grammarText = r"""
        start = outer(content: inner)
        outer(content) = outerWrap:content
        inner = payload:'a'
      """;

      var dslParser = grammarText.toSMParser(captureTokensAsMarks: true);
      var dslOutcome = dslParser.parse("a");

      expect(dslOutcome, isA<ParseSuccess>());
      var dslTree = const StructuredEvaluator().evaluate(dslOutcome.success()!.result.rawMarks);
      var dslOuter = dslTree["outerWrap"].first as ParseResult;

      expect(dslTree.span, equals("a"));
      expect(dslOuter["payload"].first.span, equals("a"));

      late Rule start;
      late Rule outer;
      late Rule inner;

      inner = Rule("inner", () => Label("payload", Pattern.char("a")));
      outer = Rule("outer", () => Label("outerWrap", ParameterRefPattern("content")));
      start = Rule("start", () => outer(arguments: {"content": CallArgumentValue.rule(inner)}));

      var fluentParser = SMParser(Grammar(() => start), captureTokensAsMarks: true);
      var fluentOutcome = fluentParser.parse("a");

      expect(fluentOutcome, isA<ParseSuccess>());
      var fluentTree = const StructuredEvaluator().evaluate(
        (fluentOutcome as ParseSuccess).result.rawMarks,
      );
      var fluentOuter = fluentTree["outerWrap"].first as ParseResult;

      expect(fluentTree.span, equals("a"));
      expect(fluentOuter["payload"].first.span, equals("a"));
    });
  });
}
