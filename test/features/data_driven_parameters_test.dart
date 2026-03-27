import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Data-driven parameter materialization", () {
    // A one-character string should follow the same parameter-materialization
    // path as longer strings, not a separate fast-path with different behavior.
    test("consumes single-character string parameters in sequence", () {
      const grammarText = r"""
        start = segment(open: "ab", body: "x", close: "cd")

        segment(open, body, close) =
              open body close
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("abxcd"), isTrue);
      expect(parser.recognize("abyd"), isFalse);
    });

    // Multi-character strings are expanded into a cached parser chain so the
    // runtime can match them as literal input.
    test("consumes multi-character string parameters in sequence", () {
      const grammarText = r"""
        start = segment(open: "ab", close: "cd")

        segment(open, close) =
              open body close

        body = 'x' 'y'
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("abxycd"), isTrue);
      expect(parser.recognize("abxcd"), isFalse);
      expect(parser.recognize("abxyc"), isFalse);
    });

    // Empty strings behave like epsilon and should not consume input.
    test("supports empty string parameters as zero-width materializations", () {
      const grammarText = r"""
        start = segment(open: "", close: "cd")

        segment(open, close) =
              open 'x' close
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("xcd"), isTrue);
      expect(parser.recognize("cd"), isFalse);
      expect(parser.recognize("xxcd"), isFalse);
    });

    // Predicate parameters must look ahead against the same string chain that
    // sequence parameters use.
    test("supports positive lookahead over multi-character string parameters", () {
      const grammarText = r"""
        start = probe(close: "cd")

        probe(close) =
              'a' &close close
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("acd"), isTrue);
      expect(parser.recognize("axd"), isFalse);
      expect(parser.recognize("ab"), isFalse);
    });

    // Negative lookahead reuses the same parameter string machinery, but only
    // resumes when the candidate does *not* match.
    test("supports negative lookahead over multi-character string parameters", () {
      const grammarText = r"""
        start = probe(close: "cd")

        probe(close) =
              'a' !close 'x'
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("ax"), isTrue);
      expect(parser.recognize("acd"), isFalse);
      expect(parser.recognize("acx"), isFalse);
    });

    // Rule values should pass through as parser objects, not get flattened into
    // text, so body-position parameters can behave like real subparsers.
    test("passes rule objects through as parser parameters", () {
      late Rule start;
      late Rule wrapper;
      late Rule letter;

      letter = Rule("letter", () => Token(const ExactToken(97)));
      wrapper = Rule("wrapper", () => ParameterRefPattern("rule") >> ParameterRefPattern("rule"));
      start = Rule(
        "start",
        () => wrapper(arguments: {"rule": CallArgumentValue.rule(letter)}) >> letter,
      );

      var parser = SMParser(Grammar(() => start));

      expect(parser.recognize("aaa"), isTrue);
      expect(parser.recognize("aa"), isFalse);
    });

    // The String DSL should be able to pass the same rule object through a
    // parameter and consume it twice in the body.
    test("grammar file passes rule objects through as parser parameters", () {
      const grammarText = r"""
        start = wrapper(rule: letter) letter

        wrapper(rule) = rule rule
        letter = 'a'
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("aaa"), isTrue);
      expect(parser.recognize("aa"), isFalse);
    });

    // A RuleCall should survive the data-driven path as a Pattern parameter,
    // then resolve back into a nested call when the wrapper consumes it.
    test("passes rule calls through as parser parameters", () {
      late Rule start;
      late Rule wrapper;
      late Rule pair;
      late Rule atom;

      atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b"));
      pair = Rule("pair", () => ParameterRefPattern("piece") >> ParameterRefPattern("piece"));
      wrapper = Rule(
        "wrapper",
        () => Pattern.char("[") >> ParameterRefPattern("content") >> Pattern.char("]"),
      );
      start = Rule(
        "start",
        () =>
            wrapper(
              arguments: {
                "content": CallArgumentValue.pattern(
                  pair(arguments: {"piece": CallArgumentValue.pattern(atom())}),
                ),
              },
            ) >>
            atom(),
      );

      var parser = SMParser(Grammar(() => start));

      expect(parser.recognize("[aa]a"), isTrue);
      expect(parser.recognize("[bb]b"), isTrue);
      expect(parser.recognize("[ad]a"), isFalse);
    });

    // The String DSL should also be able to pass a nested rule call as a
    // pattern parameter and expand it at runtime.
    test("grammar file passes rule calls through as parser parameters", () {
      const grammarText = r"""
        start = wrapper(content: pair(piece: atom)) atom

        wrapper(content) = '[' content ']'
        pair(piece) = piece piece
        atom = 'a' | 'b'
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("[aa]a"), isTrue);
      expect(parser.recognize("[bb]b"), isTrue);
      expect(parser.recognize("[ad]a"), isFalse);
    });

    // Complex pattern values should be hoisted into callable synthetic rules
    // so they can close over caller parameters and behave like higher-order
    // parser values.
    test("passes complex pattern closures through as parser parameters", () {
      late Rule start;
      late Rule outer;
      late Rule frame;
      late Rule atom;

      atom = Rule("atom", () => Pattern.char("a") | Pattern.char("b"));
      frame = Rule(
        "frame",
        () => Pattern.char("[") >> ParameterRefPattern("content") >> Pattern.char("]"),
      );
      outer = Rule(
        "outer",
        () =>
            frame(
              arguments: {
                "content": CallArgumentValue.pattern(
                  ParameterRefPattern("piece") >> ParameterRefPattern("piece"),
                ),
              },
            ) >>
            ParameterRefPattern("piece"),
      );
      start = Rule("start", () => outer(arguments: {"piece": CallArgumentValue.rule(atom)}));

      var parser = SMParser(Grammar(() => start));

      expect(parser.recognize("[aa]a"), isTrue);
      expect(parser.recognize("[bb]b"), isTrue);
      expect(parser.recognize("[ac]a"), isFalse);
    });

    // The String DSL should be able to mirror the same closure-style pattern
    // value and resolve its outer parameter when the wrapper consumes it.
    test("grammar file passes complex pattern closures through as parser parameters", () {
      const grammarText = r"""
        start = outer(piece: atom)

        outer(piece) = frame(content: pair(piece: piece)) piece
        frame(content) = '[' content ']'
        pair(piece) = piece piece

        atom = 'a' | 'b'
      """;

      var parser = grammarText.toSMParser();

      expect(parser.recognize("[aa]a"), isTrue);
      expect(parser.recognize("[bb]b"), isTrue);
      expect(parser.recognize("[ac]a"), isFalse);
    });
  });
}
