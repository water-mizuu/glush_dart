import 'package:glush/glush.dart';

void main() {
  final parser = r"""
    expr = [0-9]+ $num
  """.toSMParser();

  final input = "123";
  try {
    final result = parser.parseAmbiguous(input);

    if (result is ParseAmbiguousForestSuccess) {
      for (final path in result.forest.allPaths()) {
        print("Path: $path");
        final tree = StructuredEvaluator().evaluate(path);
        print("Tree: $tree");
        // In this case, we expect 'num' to be a label if it worked, 
        // but StructuredEvaluator might be doing something else.
      }
    } else {
      print("Parse failed");
    }
  } catch (e, st) {
    print("Caught error: $e");
    print(st);
  }
}
