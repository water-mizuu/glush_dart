// ignore_for_file: strict_raw_type, unreachable_from_main

import "package:glush/glush.dart";
import "package:glush/src/compiler/metagrammar_evaluator.dart";

void main() {
  var parser = metaGrammarString.toSMParser();
  var input = metaGrammarString;
  var parseResult = parser.parse(input).success()!.rawMarks;
  print(display(input, parseResult));
}

String display(String input, List<Mark> marks) {
  StringBuffer buffer = StringBuffer();
  int level = 0;
  int currentPos = 0;
  int i = 0;
  while (i < marks.length) {
    /// If it's a leaf node (it is succeeded by an end IMMEDIATELY.)
    ///   Then catch the span.
    if (i + 1 < marks.length) {
      var current = marks[i];
      var succeeding = marks[i + 1];

      if (current is LabelStartMark &&
          succeeding is LabelEndMark &&
          current.name == succeeding.name) {
        var start = currentPos;
        var end = currentPos;
        var name = current.name;

        buffer.write("  " * (level + 1));
        var span = input.substring(start, end);
        span = span.replaceAll("\r", r"\r");
        span = span.replaceAll("\n", r"\n");
        buffer.writeln("<$name>$span</$name>");
        i += 2;
        continue;
      }
    }

    /// Else, fall back to regular printing.
    if (marks[i] case LabelStartMark(:var name)) {
      level += 1;
      buffer.write("  " * level);
      buffer.writeln("<$name>");
    } else if (marks[i] case TokenMark(:var length)) {
      currentPos += length;
    } else if (marks[i] case LabelEndMark(:var name)) {
      buffer.write("  " * level);
      buffer.writeln("</$name>");
      level -= 1;
    }
    ++i;
  }

  return buffer.toString();
}
