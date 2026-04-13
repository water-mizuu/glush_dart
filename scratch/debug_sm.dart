import "package:glush/glush.dart";

void main() {
  var grammar = Grammar(() {
    var a = Token(const ExactToken(97)); // 'a'
    var b = Token(const ExactToken(98)); // 'b'
    var c = Token(const ExactToken(99)); // 'c'
    var pattern = (b >> c).not() >> a >> b.maybe();
    return Rule("test", () => pattern);
  });

  var parser = SMParser(grammar);
  print(parser.toDot());
}
