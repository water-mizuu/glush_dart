import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Conjunction & Alternation Properties", () {
    test("Commutativity (A & B) == (B & A)", () {
      var grammar1 = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        var any = Token(const AnyToken());

        // (a b) & (a .)
        var left = Rule("left", () => a >> b);
        var right = Rule("right", () => a >> any);
        return Rule("test", () => left & right);
      });

      var grammar2 = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        var any = Token(const AnyToken());

        // (a .) & (a b)
        var left = Rule("left", () => a >> any);
        var right = Rule("right", () => a >> b);
        return Rule("test", () => left & right);
      });

      var parser1 = SMParser(grammar1);
      var parser2 = SMParser(grammar2);
      var input = "ab";

      expect(parser1.recognize(input), isTrue);
      expect(parser2.recognize(input), isTrue);
      expect(parser1.countAllParses(input), equals(parser2.countAllParses(input)));

      expect(parser1.recognize("aa"), isFalse);
      expect(parser2.recognize("aa"), isFalse);
    });

    test("Commutativity (A | B) == (B | A)", () {
      var grammar1 = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("test", () => a | b);
      });

      var grammar2 = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("test", () => b | a);
      });

      var parser1 = SMParser(grammar1);
      var parser2 = SMParser(grammar2);

      expect(parser1.recognize("a"), isTrue);
      expect(parser2.recognize("a"), isTrue);
      expect(parser1.recognize("b"), isTrue);
      expect(parser2.recognize("b"), isTrue);
      expect(parser1.countAllParses("a"), equals(1));
      expect(parser2.countAllParses("a"), equals(1));
    });

    test("Associativity (A & B) & C == A & (B & C)", () {
      var grammar1 = Grammar(() {
        var a = Pattern.char("a");
        var ambA = Rule("ambA", () => a | a);
        var inner = Rule("inner", () => ambA & a);
        return Rule("test", () => inner & a);
      });

      var grammar2 = Grammar(() {
        var a = Pattern.char("a");
        var ambA = Rule("ambA", () => a | a);
        var inner = Rule("inner", () => a & a);
        return Rule("test", () => ambA & inner);
      });

      var parser1 = SMParser(grammar1);
      var parser2 = SMParser(grammar2);
      var input = "a";

      expect(parser1.recognize(input), isTrue);
      expect(parser2.recognize(input), isTrue);
      expect(parser1.countAllParses(input), equals(2));
      expect(parser2.countAllParses(input), equals(2));
    });

    test("Distributivity A & (B | C) == (A & B) | (A & C)", () {
      var grammar1 = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("test", () => a & (a | b));
      });

      var grammar2 = Grammar(() {
        var a = Pattern.char("a");
        var b = Pattern.char("b");
        return Rule("test", () => (a & a) | (a & b));
      });

      var parser1 = SMParser(grammar1);
      var parser2 = SMParser(grammar2);

      expect(parser1.recognize("a"), isTrue);
      expect(parser2.recognize("a"), isTrue);
      expect(parser1.recognize("b"), isFalse);
      expect(parser2.recognize("b"), isFalse);

      expect(parser1.countAllParses("a"), equals(1));
      expect(parser2.countAllParses("a"), equals(1));
    });

    test("Recursive Conjunction Rendezvous", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        late Rule L;
        L = Rule("L", () => (a >> L.call()) | Eps());
        late Rule R;
        R = Rule("R", () => (a >> R.call()) | Eps());
        return Rule("test", () => L & R);
      });

      var parser = SMParser(grammar);

      expect(parser.recognize(""), isTrue);
      expect(parser.recognize("a"), isTrue);
      expect(parser.recognize("aa"), isTrue);
      expect(parser.recognize("aaa"), isTrue);

      expect(parser.countAllParses("aa"), equals(1));
    });

    test("Mismatch Length Failure", () {
      var grammar = Grammar(() {
        var a = Pattern.char("a");
        return Rule("test", () => (a >> a) & a);
      });

      var parser = SMParser(grammar);
      expect(parser.recognize("a"), isFalse);
      expect(parser.recognize("aa"), isFalse);
    });

    test("Nested Conjunction Marks Structure Recovery", () {
      var a = Pattern.char("a");
      var grammar = Grammar(() {
        var l1 = Label("l1", a);
        var l2 = Label("l2", a);
        return Rule("test", () => l1 & l2);
      });

      var parser = SMParser(grammar);
      var input = "a";
      expect(parser.recognize(input), isTrue);

      var res = parser.parseAmbiguous(input, captureTokensAsMarks: true);
      expect(res, isA<ParseAmbiguousSuccess>());
      var success = res as ParseAmbiguousSuccess;

      // Evaluate the structure from the marks of the first derivation
      var root = success.forest.allPaths().single.evaluateStructure();

      // We expect BOTH l1 and l2 to be present in the children
      expect(root.get("l1"), isNotEmpty, reason: "Label l1 should be recovered");
      expect(root.get("l2"), isNotEmpty, reason: "Label l2 should be recovered");

      expect(root.get("l1").first.span, equals("a"));
      expect(root.get("l2").first.span, equals("a"));
      expect(root.span, equals("a"), reason: "Total span should not be duplicated");
    });
    test("Complex Nested Labeling Structure", () {
      var a = Pattern.char("a");
      var b = Pattern.char("b");
      var grammar = Grammar(() {
        var l1 = Label("l1", a >> Label("l2", b));
        var l3 = Label("l3", Label("l4", a) >> b);
        return Rule("test", () => l1 & l3);
      });

      var parser = SMParser(grammar);
      var input = "ab";
      expect(parser.recognize(input), isTrue);

      var res = parser.parseAmbiguous(input, captureTokensAsMarks: true);
      var success = res as ParseAmbiguousSuccess;
      var root = success.forest.allPaths().single.evaluateStructure();

      // Check l1 hierarchy
      var l1 = root.get("l1").first as ParseResult;
      expect(l1.get("l2"), isNotEmpty);
      expect(l1.get("l2").first.span, equals("b"));

      // Check l3 hierarchy
      var l3 = root.get("l3").first as ParseResult;
      expect(l3.get("l4"), isNotEmpty);
      expect(l3.get("l4").first.span, equals("a"));

      expect(root.span, equals("ab"));
    });
  });
}
