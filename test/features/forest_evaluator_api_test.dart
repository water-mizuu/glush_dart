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
  });
}
