import "package:glush/glush.dart";
import "package:test/test.dart";

int _tailCallActionCount(SMParser parser) {
  return parser.stateMachine.states
      .expand((state) => state.actions)
      .whereType<TailCallAction>()
      .length;
}

void main() {
  group("Tail Call Optimization", () {
    test("kicks in for direct right-tail self recursion", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule(
          "S",
          () =>
              Token.char("s") | //
              Token.char("s") >> Token.char("+") >> s.call(),
        );
        return s;
      });

      var parser = SMParser(grammar);
      expect(_tailCallActionCount(parser), greaterThan(0));

      expect(parser.recognize("s+" * 80 + "s"), isTrue);
    });

    test("does not kick in for left recursion", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule(
          "S",
          () =>
              Token.char("s") | //
              s.call() >> Token.char("+") >> Token.char("s"),
        );
        return s;
      });

      var parser = SMParser(grammar);
      expect(_tailCallActionCount(parser), equals(0));
      expect(parser.recognize("s+" * 40 + "s"), isTrue);
      expect(parser.parseAmbiguous("s+" * 40 + "s"), isA<ParseAmbiguousSuccess>());
    });

    test("does not kick in when the recursive step may fail to make progress", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule(
          "S",
          () =>
              Token.char("s") | //
              Token.char("+").maybe() >> s.call(),
        );
        return s;
      });

      var parser = SMParser(grammar);
      expect(_tailCallActionCount(parser), equals(0));

      expect(parser.recognize("s"), isTrue);
      expect(parser.recognize("+++s"), isTrue);
    });

    test("kicks in for right-tail recursion wrapped in action", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule(
          "S",
          () =>
              Token.char("s") |
              (Token.char("s") >> Token.char("+") >> s.call()).withAction((span, _) => span),
        );
        return s;
      });

      var parser = SMParser(grammar);
      expect(_tailCallActionCount(parser), greaterThan(0));

      expect(parser.recognize("s+" * 20 + "s"), isTrue);
      expect(parser.parseAmbiguous("s+" * 20 + "s"), isA<ParseAmbiguousSuccess>());
    });

    test("kicks in for right-tail recursion followed by dead epsilon suffix", () {
      var grammar = Grammar(() {
        late Rule s;
        s = Rule("S", () => Token.char("s") | (Token.char("s") >> s.call() >> Eps()));

        return s;
      });

      var parser = SMParser(grammar);
      expect(_tailCallActionCount(parser), greaterThan(0));

      expect(parser.recognize("ssssssssssssssssssss"), isTrue);
    });
  });
}
