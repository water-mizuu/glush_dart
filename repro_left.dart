import 'package:glush/glush.dart';

void main() {
  final parser = r"""
      file = commentPlus
      commentPlus = commentPlus [\n\r]* comment
                  | comment

      comment = '#' (![\n\r] .)*
    """.toSMParser();

  const input = """
# abc
# def
""";

  final result = parser.parseAmbiguous(input.trim());

  if (result is ParseAmbiguousForestSuccess) {
    for (final path in result.forest.allPaths()) {
      print("Path: ${path.map((m) => m.toString()).toList()}");
      final tree = StructuredEvaluator().evaluate(path);
      print("Tree span: '${tree.span}'");
    }
  } else {
    print("Parse failed");
  }
}
