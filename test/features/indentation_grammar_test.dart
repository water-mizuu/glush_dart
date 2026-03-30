import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Indentation Grammar (Engine Fixed)", () {
    late SMParser parser;
    late Rule indent;
    late Rule indentStep;
    late Rule indentBase;
    late Rule program;
    late Rule block;
    late Rule stmt;
    late Rule nested;
    var space = Token.char(" ");
    var colon = Token.char(":");
    var newline = Token.char("\n");
    var code = Token.charRange("a", "z").plus();

    setUp(() {
      // indent(target) matches exactly target spaces.
      // It respects target == 0 for Base and target > 0 for Step.
      indent = Rule("indent", () {
        var target = CallArgumentValue.reference("target");
        return indentStep.call(arguments: {"target": target}) |
            indentBase.call(arguments: {"target": target});
      });

      indentStep = Rule("indent_step", () {
        return indent.call(
              arguments: {
                "target": CallArgumentValue.binary(
                  CallArgumentValue.reference("target"),
                  ExpressionBinaryOperator.subtract,
                  CallArgumentValue.literal(1),
                ),
              },
            ) >>
            space;
      }).guardedBy(GuardValue.argument("target").gt(0));

      indentBase = Rule("indent_base", () => Eps()).guardedBy(GuardValue.argument("target").eq(0));

      // block(lvl)
      block = Rule("block", () {
        var lvl = CallArgumentValue.reference("lvl");
        return (stmt.call(arguments: {"lvl": lvl}) | nested.call(arguments: {"lvl": lvl})).plus();
      });

      // stmt(lvl) = indent(lvl) >> code >> newline
      stmt = Rule("stmt", () {
        var lvl = CallArgumentValue.reference("lvl");
        return indent.call(arguments: {"target": lvl}) >> code >> newline;
      });

      // nested(lvl) = indent(lvl) >> ":" >> newline >> block(lvl + 4)
      nested = Rule("nested", () {
        var lvl = CallArgumentValue.reference("lvl");
        return indent.call(arguments: {"target": lvl}) >>
            colon >>
            newline >>
            block.call(
              arguments: {
                "lvl": CallArgumentValue.binary(
                  lvl,
                  ExpressionBinaryOperator.add,
                  CallArgumentValue.literal(4),
                ),
              },
            );
      });

      program = Rule("program", () => block.call(arguments: {"lvl": CallArgumentValue.literal(0)}));

      parser = SMParser(Grammar(() => program));
    });

    test("simple lines at level 0", () {
      expect(parser.recognize("aaa\nbbb\n"), isTrue);
    });

    test("nested block with 4 spaces", () {
      expect(
        parser.recognize(
          ":\n"
          "    aaa\n",
        ),
        isTrue,
      );
    });

    test("multi-level nesting (0, 4, 8)", () {
      expect(
        parser.recognize(
          "aaa\n"
          ":\n"
          "    bbb\n"
          "    :\n"
          "        ccc\n"
          "    ddd\n"
          "eee\n",
        ),
        isTrue,
      );
    });

    test("rejects incorrect indentation (2 spaces instead of 4)", () {
      expect(
        parser.recognize(
          ":\n"
          "  aaa\n",
        ),
        isFalse,
      );
    });

    test("rejects shallow indentation (4 spaces inside 8-level block)", () {
      expect(
        parser.recognize(
          ":\n"
          "    :\n"
          "        aaa\n"
          "    bbb\n", // This is actually VALID in Python (return to previous level)
        ),
        isTrue,
      );
    });

    test("rejects mixed invalid indentation", () {
      expect(
        parser.recognize(
          ":\n"
          "     aaa\n", // 5 spaces instead of 4
        ),
        isFalse,
      );
    });
  });
}
