import 'package:glush/glush.dart';
import 'package:test/test.dart';

void main() {
  test('State machine DOT export clusters predicate subparses', () {
    final parser =
        r"""
      S = !'a' 'b' | 'a'
    """
            .toSMParser();

    final dot = parser.toDot();

    expect(dot, contains('subgraph cluster_predicate_'));
    expect(dot, contains('label="predicate pred'));
    expect(dot, contains(r'S2" -> "S6" [label="NOT'));
    expect(dot, contains(r'S7" -> "S5" [label="NOT'));
    expect(dot, isNot(contains('not(<pred')));
  });
}
