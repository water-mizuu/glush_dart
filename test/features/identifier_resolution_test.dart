import "package:glush/glush.dart";
import "package:test/test.dart";

void main() {
  group("Identifier resolution order", () {
    test("parameters should shadow rules", () {
      const grammarText = r'''
        start = shadow("parameter")
        other = "rule"
        shadow(other) = if (other == "parameter") "a"
      ''';

      var parser = grammarText.toSMParser();
      // If it works, 'other' in 'shadow' refers to the parameter "parameter".
      expect(parser.recognize("a"), isTrue);
    });

    test("parameters should shadow builtins", () {
      const grammarText = r'''
        start = shadow("parameter")
        shadow(rule) = if (rule == "parameter") "a"
      ''';

      var parser = grammarText.toSMParser();
      // If it works, 'rule' in 'shadow' refers to the parameter "parameter",
      // not the 'rule' builtin.
      expect(parser.recognize("a"), isTrue);
    });

    test("rules should shadow builtins", () {
      const grammarText = r'''
        start = my_eof
        my_eof = eof
        eof = "end"
      ''';

      var parser = grammarText.toSMParser();
      // If it works, 'eof' in 'my_eof' refers to the 'eof' rule, not the builtin.
      expect(parser.recognize("end"), isTrue);
      expect(parser.recognize(""), isFalse); // builtin eof would recognize empty at end, but here it must be "end"
    });
  });
}
