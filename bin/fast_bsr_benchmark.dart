import 'package:glush/glush.dart';
import 'package:glush/src/sm_parser.dart';

void main() async {
  late final Rule m;
  m = Rule('M', () => Alt(Seq(Seq(Pattern.char('a'), Marker('m')), m.call()), Pattern.char('a')));

  final grammar = Grammar(() => m.call());
  final parserFast = SMParser(grammar, fastMode: true);
  final parserNormal = SMParser(grammar, fastMode: false);

  final inputSizes = [100, 500, 1000, 2000, 5000];

  print('Input Size | Fast Mode (ms) | Normal Mode (ms) | Speedup');
  print('-----------|----------------|------------------|---------');

  for (final size in inputSizes) {
    final input = 'a' * size;

    // Warmup
    parserFast.recognize(input);
    if (size <= 1000) parserNormal.recognize(input);

    final swFast = Stopwatch()..start();
    for (int i = 0; i < 3; i++) {
      parserFast.recognize(input);
    }
    swFast.stop();
    final avgFast = swFast.elapsedMilliseconds / 3;

    double avgNormal = 0;
    if (size <= 10000) {
      final swNormal = Stopwatch()..start();
      try {
        for (int i = 0; i < 3; i++) {
          parserNormal.recognize(input);
        }
        swNormal.stop();
        avgNormal = swNormal.elapsedMilliseconds / 3;
      } catch (e) {
        avgNormal = double.infinity;
      }
    } else {
      avgNormal = -1; // Skip for large sizes
    }

    final speedup = avgNormal > 0 ? (avgNormal / (avgFast == 0 ? 1 : avgFast)) : 0;
    final normalStr = avgNormal >= 0 ? avgNormal.toStringAsFixed(2) : 'SKIPPED';
    final speedupStr = avgNormal >= 0 ? '${speedup.toStringAsFixed(2)}x' : 'N/A';

    print(
        '${size.toString().padRight(10)} | ${avgFast.toStringAsFixed(2).padRight(14)} | ${normalStr.padRight(16)} | $speedupStr');
  }
}
