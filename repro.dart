import 'package:glush/glush.dart';

void main() {
  final parser = r"""
    expr = $num [0-9]+
  """.toSMParser();

  final input = "123";
  final result = parser.parseAmbiguous(input);

  if (result is ParseAmbiguousForestSuccess) {
    for (final path in result.forest.allPaths()) {
      print("Path: $path");
      final tree = StructuredEvaluator().evaluate(path);
      print("Tree: $tree");
      print("Tree['num'].span: ${tree['num'].isNotEmpty ? tree['num'].first.span : 'NOT FOUND'}");
    }
  } else {
    print("Parse failed");
  }
}
