import "package:glush/glush.dart";

void main() {
  var grammar = Grammar(() {
    var digit = Token.charRange("0", "9");
    var even =
        Token(const ExactToken(48)) |
        Token(const ExactToken(50)) |
        Token(const ExactToken(52)) |
        Token(const ExactToken(54)) |
        Token(const ExactToken(56));
    var evenDigit = digit & even;
    return Rule("test", () => evenDigit);
  });

  var parser = SMParser(grammar);
  print("Recognize '0': ${parser.recognize("0")}");

  try {
    print("Count parses '0': ${parser.countAllParses("0")}");
  } on Object catch (e) {
    print("Count parses '0' failed: $e");
  }

  try {
    for (var d in parser.enumerateAllParses("0")) {
      print("Derivation: $d");
    }
  } on Object catch (e) {
    print("Enumerate parses '0' failed: $e");
  }
}
