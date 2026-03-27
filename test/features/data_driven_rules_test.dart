import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Data-driven rule calls", () {
    // The memoization key needs to stay stable even when the argument map is
    // written in a different order.
    test("RuleCall retains call arguments and a stable arguments key", () {
      var rule = Rule("test", () => Eps());
      var other = Rule("other", () => Eps());

      var first = rule(
        arguments: {
          "name": CallArgumentValue.literal("alpha"),
          "count": CallArgumentValue.literal(7),
          "enabled": CallArgumentValue.literal(true),
          "rule": CallArgumentValue.rule(rule),
          "nested": CallArgumentValue.map({"nested": CallArgumentValue.rule(other)}),
        },
      );
      var second = rule(
        arguments: {
          "nested": CallArgumentValue.map({"nested": CallArgumentValue.rule(other)}),
          "rule": CallArgumentValue.rule(rule),
          "enabled": CallArgumentValue.literal(true),
          "count": CallArgumentValue.literal(7),
          "name": CallArgumentValue.literal("alpha"),
        },
      );

      expect(first.arguments, hasLength(5));
      expect(first.arguments["name"]!.resolve(GuardEnvironment(rule: rule)), equals("alpha"));
      expect(first.arguments["rule"]!.resolve(GuardEnvironment(rule: rule)), same(rule));
      expect(first.argumentsKey, isNotEmpty);
      expect(first.argumentsKey, equals(second.argumentsKey));
      expect(first.toString(), contains("alpha"));
      expect(first.toString(), contains("test"));
    });

    // This exercises the tagged argument model: literals, references, rules,
    // lists, and maps all need to resolve through the environment correctly.
    test("CallArgumentValue supports references, lists, and maps", () {
      var rule = Rule("test", () => Eps());
      var pattern = Token.char("a");
      var call = rule(
        arguments: {
          "scalar": CallArgumentValue.literal(3),
          "ref": CallArgumentValue.reference("mode"),
          "pattern": CallArgumentValue.pattern(pattern),
          "list": CallArgumentValue.list([
            CallArgumentValue.literal("x"),
            CallArgumentValue.reference("mode"),
            CallArgumentValue.rule(rule),
          ]),
          "map": CallArgumentValue.map({"nested": CallArgumentValue.literal(true)}),
        },
      );
      var env = GuardEnvironment(rule: rule, values: {"mode": "active"});

      expect(call.arguments["scalar"]!.resolve(env), equals(3));
      expect(call.arguments["ref"]!.resolve(env), equals("active"));
      expect(call.arguments["pattern"]!.resolve(env), same(pattern));
      expect(call.arguments["list"]!.resolve(env), equals(["x", "active", rule]));
      expect(call.arguments["map"]!.resolve(env), equals({"nested": true}));
      expect(call.argumentsKey, isNotEmpty);
    });

    // Guards must be enforced before the callee body runs so the state machine
    // can reject invalid calls without entering the rule.
    test("guard expressions are enforced before the body is entered", () {
      Grammar buildGrammar({required String mode, required int count}) {
        late Rule expr;
        var a = Token(const ExactToken(97));
        var b = Token(const ExactToken(98));

        expr = Rule("expr", () => a >> b);
        expr.guard =
            GuardValue.argument("mode").eq("enabled") &
            GuardValue.argument("count").gte(2) &
            GuardValue.argument("target").eq(expr);

        var start = Rule(
          "start",
          () => expr(
            arguments: {
              "mode": CallArgumentValue.literal(mode),
              "count": CallArgumentValue.literal(count),
              "target": CallArgumentValue.rule(expr),
            },
          ),
        );
        return Grammar(() => start);
      }

      expect(SMParser(buildGrammar(mode: "enabled", count: 3)).recognize("ab"), isTrue);

      expect(SMParser(buildGrammar(mode: "enabled", count: 1)).recognize("ab"), isFalse);
    });

    // A lenient policy should describe a different accepted shape rather than
    // merely failing the strict one.
    test("guarded policy branches can model strict and lenient shapes", () {
      late Rule start;
      late Rule looseStart;
      late Rule strictGuarded;
      late Rule lenientGuarded;
      late Rule wrapper;
      late Rule pair;
      late Rule atom;

      atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b") | Pattern.char("c"));
      pair = Rule("pair", () => ParameterRefPattern("piece") >> ParameterRefPattern("piece"));
      wrapper = Rule(
        "wrapper",
        () =>
            Pattern.char("[") >>
            pair(arguments: {"piece": CallArgumentValue.rule(atom)}) >>
            Pattern.char("]"),
      );

      strictGuarded = Rule("guardedStrict", () => ParameterRefPattern("content") >> atom());
      strictGuarded.guard = GuardValue.argument("policy").eq("strict");

      lenientGuarded = Rule("guardedLenient", () => ParameterRefPattern("content"));
      lenientGuarded.guard = GuardValue.argument("policy").eq("lenient");

      start = Rule(
        "start",
        () => strictGuarded(
          arguments: {
            "content": CallArgumentValue.rule(wrapper),
            "policy": CallArgumentValue.literal("strict"),
          },
        ),
      );
      looseStart = Rule(
        "looseStart",
        () => lenientGuarded(
          arguments: {
            "content": CallArgumentValue.rule(wrapper),
            "policy": CallArgumentValue.literal("lenient"),
          },
        ),
      );

      expect(SMParser(Grammar(() => start)).recognize("[aa]a"), isTrue);
      expect(SMParser(Grammar(() => looseStart)).recognize("[aa]"), isTrue);
      expect(SMParser(Grammar(() => looseStart)).recognize("[aa]a"), isFalse);
    });

    // The String DSL should mirror the same strict/lenient guarded shapes.
    test("grammar file can model strict and lenient policy branches", () {
      const grammarText = r"""
        start = strict | lenient

        strict = invoke(payload: wrapper, policy: "strict")
        lenient = invoke(payload: wrapper, policy: "lenient")

        invoke(payload, policy) =
              if (policy == "strict") payload(piece: atom) atom
            | if (policy == "lenient") payload(piece: atom)

        wrapper = '[' pair(piece: atom) ']'
        pair(piece) = piece piece
        atom = 'a' | 'b' | 'c'
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("[aa]a"), isTrue);
      expect(parser.recognize("[aa]"), isTrue);
      expect(parser.recognize("[aa]d"), isFalse);
    });

    // The grammar-file compiler should lower parameter invocations with named
    // arguments into a real runtime call, not reject them at compile time.
    test("grammar file supports invoking a parameter with named arguments", () {
      const grammarText = r"""
        start = strict | lenient

        strict = invoke(payload: wrapper, policy: "strict")
        lenient = invoke(payload: wrapper, policy: "lenient")

        invoke(payload, policy) =
              if (policy == "strict") payload(piece: atom) atom
            | if (policy == "lenient") payload(piece: atom)

        wrapper = '[' pair(piece: atom) ']'
        pair(piece) = piece piece
        atom = 'a' | 'b' | 'c'
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("[aa]a"), isTrue);
      expect(parser.recognize("[aa]"), isTrue);
      expect(parser.recognize("[aa]d"), isFalse);
    });

    // The fluent API should be able to express the same named-argument
    // parameter invocation and guarded strict/lenient split.
    test("fluent API supports invoking a parameter with named arguments", () {
      late Rule start;
      late Rule strictStart;
      late Rule lenientStart;
      late Rule invokeStrict;
      late Rule invokeLenient;
      late Rule wrapper;
      late Rule pair;
      late Rule atom;

      atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b") | Pattern.char("c"));
      pair = Rule("pair", () => ParameterRefPattern("piece") >> ParameterRefPattern("piece"));
      wrapper = Rule(
        "wrapper",
        () =>
            Pattern.char("[") >>
            pair(arguments: {"piece": CallArgumentValue.rule(atom)}) >>
            Pattern.char("]"),
      );

      invokeStrict = Rule(
        "invokeStrict",
        () =>
            ParameterCallPattern("payload", arguments: {"piece": CallArgumentValue.rule(atom)}) >>
            atom(),
      );
      invokeStrict.guard = GuardValue.argument("policy").eq("strict");

      invokeLenient = Rule(
        "invokeLenient",
        () => ParameterCallPattern("payload", arguments: {"piece": CallArgumentValue.rule(atom)}),
      );
      invokeLenient.guard = GuardValue.argument("policy").eq("lenient");

      strictStart = Rule(
        "strictStart",
        () => invokeStrict(
          arguments: {
            "payload": CallArgumentValue.rule(wrapper),
            "policy": CallArgumentValue.literal("strict"),
          },
        ),
      );

      lenientStart = Rule(
        "lenientStart",
        () => invokeLenient(
          arguments: {
            "payload": CallArgumentValue.rule(wrapper),
            "policy": CallArgumentValue.literal("lenient"),
          },
        ),
      );

      start = Rule("start", () => strictStart | lenientStart);

      var parser = SMParser(Grammar(() => start));

      expect(parser.recognize("[aa]a"), isTrue);
      expect(parser.recognize("[aa]"), isTrue);
      expect(parser.recognize("[aa]d"), isFalse);
    });

    // A parameter can call another parameterized rule, which then delegates
    // to a third rule. This keeps the higher-order chain working through the
    // grammar-file compiler.
    test("grammar file supports recursive parameter calls with named arguments", () {
      const grammarText = r"""
        start = outer(handler: middle, item: atom)

        outer(handler, item) = handler(piece: item) item
        middle(piece) = inner(value: piece)
        inner(value) = '[' value value ']'

        atom = 'a' | 'b' | 'c'
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("[aa]a"), isTrue);
      expect(parser.recognize("[bb]b"), isTrue);
      expect(parser.recognize("[aa]"), isFalse);
      expect(parser.recognize("[ad]a"), isFalse);
    });

    // The fluent API should be able to express the same three-level chain and
    // recurse through parameter invocations in code.
    test("fluent API supports recursive parameter calls with named arguments", () {
      late Rule start;
      late Rule outer;
      late Rule middle;
      late Rule inner;
      late Rule atom;

      atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b") | Pattern.char("c"));
      inner = Rule(
        "inner",
        () =>
            Pattern.char("[") >>
            ParameterRefPattern("value") >>
            ParameterRefPattern("value") >>
            Pattern.char("]"),
      );
      middle = Rule(
        "middle",
        () => inner(arguments: {"value": CallArgumentValue.reference("piece")}),
      );
      outer = Rule(
        "outer",
        () =>
            ParameterCallPattern(
              "handler",
              arguments: {"piece": CallArgumentValue.reference("item")},
            ) >>
            ParameterRefPattern("item"),
      );
      start = Rule(
        "start",
        () => outer(
          arguments: {
            "handler": CallArgumentValue.rule(middle),
            "item": CallArgumentValue.rule(atom),
          },
        ),
      );

      var parser = SMParser(Grammar(() => start));

      expect(parser.recognize("[aa]a"), isTrue);
      expect(parser.recognize("[bb]b"), isTrue);
      expect(parser.recognize("[aa]"), isFalse);
      expect(parser.recognize("[ad]a"), isFalse);
    });
  });
}
