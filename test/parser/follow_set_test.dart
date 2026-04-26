import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("StateMachine follow sets", () {
    test("canRuleEndWith uses rule follow patterns", () {
      late Rule s;
      late Rule a;

      var grammar = Grammar(() {
        a = Rule("A", () => Token.char("a"));
        s = Rule("S", () => a() >> Token.char("b"));
        return s;
      });

      var machine = SMParser(grammar).stateMachine;
      var aSymbol = a.symbolId!;

      expect(machine.canRuleEndWith(aSymbol, "b".codeUnitAt(0), isAtStart: false), isTrue);
      expect(machine.canRuleEndWith(aSymbol, "c".codeUnitAt(0), isAtStart: false), isFalse);
      expect(machine.canRuleEndWith(aSymbol, null, isAtStart: false), isFalse);
    });

    test("all grammar-assigned patterns have follow-set entries", () {
      var grammar = Grammar(() {
        late Rule s;
        late Rule t;
        t = Rule("T", () => Token.char("t").plus());
        s = Rule("S", () => (Token.char("a") >> t()) | Token.char("b").opt());
        return s;
      });

      var machine = SMParser(grammar).stateMachine;
      for (var pattern in grammar.registry.values) {
        expect(
          machine.hasFollowSetEntry(pattern),
          isTrue,
          reason: "Missing follow-set entry for assigned pattern: $pattern",
        );
      }
    });

    test("tracks follow links for first, pair, and return boundaries", () {
      late Rule start;
      late Rule aRule;
      late Rule bRule;

      var tokenA = Token.char("a");
      var tokenB = Token.char("b");

      var grammar = Grammar(() {
        aRule = Rule("A", () => tokenA.opt());
        bRule = Rule("B", () => tokenB);
        start = Rule("S", () => aRule() >> bRule());
        return start;
      });

      var machine = SMParser(grammar).stateMachine;

      var startBody = start.body() as Seq;
      var aCall = startBody.left;
      var bCall = startBody.right;

      var startFollow = machine.followSetOf(start).toSet();
      expect(startFollow.contains(aCall), isTrue);
      expect(startFollow.contains(bCall), isTrue);

      expect(machine.followSetOf(aCall).contains(bCall), isTrue);
      expect(machine.followSetOf(bCall).contains(start), isTrue);

      expect(machine.followSetOf(aRule).contains(tokenA), isTrue);
      expect(machine.followSetOf(tokenA).contains(aRule), isTrue);
    });

    test("returns empty set for patterns with no recorded followers", () {
      var stray = Token.char("z");
      var grammar = Grammar(() => Rule("S", () => Token.char("a")));
      var machine = SMParser(grammar).stateMachine;

      expect(machine.followSetOf(stray), isEmpty);
    });
  });
}
