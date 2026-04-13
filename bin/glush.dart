// ignore_for_file: strict_raw_type, unreachable_from_main

import "dart:convert";

import "package:glush/glush.dart";
import "package:glush/src/parser/common/tracer.dart";

final andParser = r"""S = & .  . .""".toSMParser();
final notParser = r"""S = !'b' . .""".toSMParser();

void main() {
  // Default behavior: parse and output
  const input = r"ss";

  var tracer1 = FileTracer("AND.log");
  var state1 = andParser.createParseState(captureTokensAsMarks: true, tracer: tracer1);
  for (int code in utf8.encode(input)) {
    state1.processToken(code);
  }
  state1.finish();

  print(state1.forest!.allMarkPaths().single.evaluateStructure());

  var tracer2 = FileTracer("NOT.log");
  var state2 = notParser.createParseState(captureTokensAsMarks: true, tracer: tracer2);
  for (int code in utf8.encode(input)) {
    state2.processToken(code);
  }
  state2.finish();
}
