import 'package:glush/glush.dart';
import 'package:glush/src/bsr.dart';
import 'package:glush/src/sm_parser.dart';

void main() {
  final grammar = Grammar(() {
    late final Rule s;
    s = Rule('S', () {
      return Token.char('s') | // s
          (s() >> s()) |
          (s() >> s() >> s()) |
          (s() >> s() >> s() >> s());
    });
    return s;
  });

  const testInput = 'ssss';
  final parser = SMParser(grammar);
  
  final derivations = parser.enumerateAllParses(testInput).toList();
  final enumTrees = derivations.map((d) => d.toTreeString(testInput)).toSet();

  print('Enumerations (${derivations.length} total):');
  for (final s in enumTrees) {
    print('  $s');
  }

  final bsrOutcome = parser.parseToBsr(testInput);
  if (bsrOutcome is BsrParseSuccess) {
    print('\nBSR Entries:');
    final entries = bsrOutcome.bsrSet.allEntries.toList();
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    for (final entry in entries) {
      print('  Slot: ${entry.$1}, Start: ${entry.$2}, Pivot: ${entry.$3}, End: ${entry.$4}');
    }
  }

  final forestResult = parser.parseWithForest(testInput);
  if (forestResult is ParseForestSuccess) {
    final forestTrees = forestResult.forest.extract().toList();
    final forestTreeStrings = forestTrees.map((t) => SMParser.parseTreeToDerivation(t, testInput).toTreeString(testInput)).toSet();
    
    print('\nForest extracted (${forestTrees.length} total):');
    for (final s in forestTreeStrings) {
      print('  $s');
    }

    print('\nMissing from forest:');
    final missing = enumTrees.difference(forestTreeStrings);
    for (final s in missing) {
      print('  $s');
    }

    print('\nExtra in forest:');
    final extra = forestTreeStrings.difference(enumTrees);
    for (final s in extra) {
      print('  $s');
    }
  }
}
