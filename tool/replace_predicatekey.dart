import 'dart:io';
void main() {
  var file = File('lib/src/parser/common/step.dart');
  var content = file.readAsStringSync();
  content = content.replaceAll(RegExp(r'PredicateKey\(\s*symbol,\s*position,\s*isAnd:\s*isAnd,\s*name:\s*name,\s*\)'), 'PredicateKey(symbol, position, isAnd: isAnd, isMirror: frameContext.isMirror, name: name)');
  content = content.replaceAll(RegExp(r'PredicateKey\(\s*symbol,\s*position,\s*isAnd:\s*action\.isAnd,\s*name:\s*action\.name,\s*\)'), 'PredicateKey(symbol, position, isAnd: action.isAnd, isMirror: frameContext.isMirror, name: action.name)');
  content = content.replaceAll('PredicateKey(symbol, position, isAnd: action.isAnd, name: action.name)', 'PredicateKey(symbol, position, isAnd: action.isAnd, isMirror: frameContext.isMirror, name: action.name)');
  content = content.replaceAll(RegExp(r'PredicateKey\(\s*caller\.pattern,\s*caller\.startPosition,\s*isAnd:\s*caller\.isAnd,\s*name:\s*caller\.name,\s*\)'), 'PredicateKey(caller.pattern, caller.startPosition, isAnd: caller.isAnd, isMirror: frame.context.isMirror, name: caller.name)');
  file.writeAsStringSync(content);
}
