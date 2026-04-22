// ignore_for_file: avoid_print

/// Trace Graph Visualizer for Glush Parser
///
/// This script reads the parser's execution trace (another.log) and generates
/// a series of DOT graphs that visualize the state machine execution step-by-step.
///
/// Each graph shows:
/// - RED states: States being processed at this step
/// - GREEN states: Next active states (waiting to be processed)
/// - GRAY states: Other states in the state machine
/// - All edges and transitions from the actual state machine
///
/// The DOT output is augmented directly from the state machine's toDot() function.
///
/// Usage:
///   1. Run: dart bin/glush.dart
///   2. Run: dart bin/visualize_trace.dart
///   3. Check the trace_graphs/ folder for generated DOT files

import "dart:io";

import "package:glush/glush.dart";

/// Represents an action being executed: from a state, what type, and to where
class ActionEdge {
  // For tokens: true if there's input, false if at EOF

  ActionEdge(this.fromStateId, this.actionType, this.toStateId, {this.isSuccessful = true});
  final int fromStateId;
  final String actionType; // "Token", "Call", "Return", etc.
  final int? toStateId; // null for Accept or Return
  final bool isSuccessful;

  @override
  String toString() =>
      "$fromStateId --[$actionType${!isSuccessful ? ' FAILED' : ''}]--> ${toStateId ?? 'accept'}";
}

/// Parse the trace log and extract state information for each position
Map<
  int,
  ({Set<int> processedStates, Set<int> nextStates, String token, List<ActionEdge> activeActions})
>
parseTraceLog(String logContent, StateMachine machine) {
  var lines = logContent.split("\n");
  var result =
      <
        int,
        ({
          Set<int> processedStates,
          Set<int> nextStates,
          String token,
          List<ActionEdge> activeActions,
        })
      >{};

  int? position;
  String token = "";
  var processedStates = <int>{};
  var nextStates = <int>{};
  var activeActions = <ActionEdge>[];
  var currentlyProcessingStates = <int>{}; // Track all states being processed in this step

  for (int i = 0; i < lines.length; i++) {
    var line = lines[i];

    // Match POSITION line
    if (line.contains("POSITION:")) {
      // Save previous
      if (position != null) {
        result[position] = (
          processedStates: Set.from(processedStates),
          nextStates: Set.from(nextStates),
          token: token,
          activeActions: List.from(activeActions),
        );
        processedStates.clear();
        nextStates.clear();
        activeActions.clear();
        currentlyProcessingStates.clear();
      }

      // Parse new position
      var match = RegExp(
        r"POSITION: (\d+), TOKEN: '(.)'|POSITION: (\d+), TOKEN: EOF",
      ).firstMatch(line);
      if (match != null) {
        position = int.parse(match.group(1) ?? match.group(3) ?? "0");
        token = match.group(2) ?? "EOF";
      }
    }

    // Extract next active states from "States: {State(...)}"
    if (line.contains("States:  {State")) {
      var matches = RegExp(r"State\((\d+)\)").allMatches(line);
      for (var match in matches) {
        nextStates.add(int.parse(match.group(1)!));
      }
    }

    // Match state processing - collect ALL states being processed
    if (line.contains("[* Process]")) {
      var match = RegExp(r"State\((\d+)\)").firstMatch(line);
      if (match != null) {
        var stateId = int.parse(match.group(1)!);
        currentlyProcessingStates.add(stateId);
        processedStates.add(stateId);
      }
    }

    // Match actions being executed - these belong to states actively being processed
    if (line.contains("[> Action]") && currentlyProcessingStates.isNotEmpty) {
      // Parse action type and target
      Set<int> targetStates = Set.from(currentlyProcessingStates);

      if (line.contains("Token(")) {
        // Token action - check if it succeeded or failed
        var isSuccessful = line.contains("matched");

        // If none of the current states have Token actions, find which states do
        bool foundInCurrent = false;
        for (var stateId in currentlyProcessingStates) {
          var state = machine.states.firstWhere((s) => s.id == stateId);
          if (state.actions.whereType<TokenAction>().isNotEmpty) {
            foundInCurrent = true;
            break;
          }
        }

        if (!foundInCurrent) {
          // Find states that have Token actions (likely inferred entry states)
          targetStates.clear();
          for (var state in machine.states) {
            if (state.actions.whereType<TokenAction>().isNotEmpty) {
              targetStates.add(state.id);
              break; // Just use the first one found
            }
          }
        }

        for (var stateId in targetStates) {
          activeActions.add(ActionEdge(stateId, "Token", null, isSuccessful: isSuccessful));
        }
      } else if (line.contains("CallAction(")) {
        // Call action
        for (var stateId in currentlyProcessingStates) {
          activeActions.add(ActionEdge(stateId, "Call", null));
        }
      } else if (line.contains("ReturnAction(")) {
        // Return action - find which states have it
        bool foundInCurrent = false;
        for (var stateId in currentlyProcessingStates) {
          var state = machine.states.firstWhere((s) => s.id == stateId);
          if (state.actions.whereType<ReturnAction>().isNotEmpty) {
            foundInCurrent = true;
            break;
          }
        }

        Set<int> returnTargetStates = Set.from(currentlyProcessingStates);
        if (!foundInCurrent) {
          // Find all states that have Return actions
          returnTargetStates.clear();
          for (var state in machine.states) {
            if (state.actions.whereType<ReturnAction>().isNotEmpty) {
              returnTargetStates.add(state.id);
            }
          }
        }

        for (var stateId in returnTargetStates) {
          activeActions.add(ActionEdge(stateId, "Return", null));
        }
      } else if (line.contains("AcceptAction")) {
        // Accept action
        for (var stateId in currentlyProcessingStates) {
          activeActions.add(ActionEdge(stateId, "Accept", null));
        }
      } else if (line.contains("TailCallAction(")) {
        // Tail call
        for (var stateId in currentlyProcessingStates) {
          activeActions.add(ActionEdge(stateId, "TailCall", null));
        }
      } else if (line.contains("MarkAction")) {
        for (var stateId in currentlyProcessingStates) {
          activeActions.add(ActionEdge(stateId, "Mark", null));
        }
      } else if (line.contains("BoundaryAction")) {
        for (var stateId in currentlyProcessingStates) {
          activeActions.add(ActionEdge(stateId, "Boundary", null));
        }
      } else if (line.contains("PredicateAction")) {
        for (var stateId in currentlyProcessingStates) {
          activeActions.add(ActionEdge(stateId, "Predicate", null));
        }
      }
    }

    // Reset processing states when we hit a separator or new position
    if (line.startsWith("=")) {
      currentlyProcessingStates.clear();
    }
  }

  // Save final
  if (position != null) {
    result[position] = (
      processedStates: processedStates,
      nextStates: nextStates,
      token: token,
      activeActions: activeActions,
    );
  }

  return result;
}

/// Generate colored DOT output, augmenting the actual state machine structure
String generateColoredDot(
  StateMachine machine,
  Set<int> currentStates,
  Set<int> nextStates,
  List<ActionEdge> activeActions,
  String inputToken,
  int position,
  int stepNum,
) {
  var buffer = StringBuffer();

  // Create a map of state + actionType -> whether it's active
  var activeActionMap = <(int, String)>{};
  for (var action in activeActions) {
    activeActionMap.add((action.fromStateId, action.actionType));
  }

  // Write graph header
  buffer.writeln("digraph StateMachine {");
  buffer.writeln("  rankdir=LR;");
  buffer.writeln('  node [fontname="Courier"];');
  buffer.writeln('  label="Step $stepNum: Position $position, Token \'$inputToken\'";');
  buffer.writeln("  labelloc=top;");
  buffer.writeln('  "__start__" [shape=point, label=""];');
  buffer.writeln('  "__accept__" [shape=doublecircle, label="accept"];');

  // Collect all return rules
  var returnRules = <PatternSymbol>{};
  for (var state in machine.states) {
    for (var action in state.actions) {
      if (action is ReturnAction) {
        returnRules.add(action.ruleSymbol);
      }
    }
  }

  // Create return nodes
  for (var symbol in returnRules) {
    var returnNodeId = "__return_${symbol}__";
    buffer.writeln(
      '  "$returnNodeId" [shape=box, label="return $symbol", style=filled, fillcolor=lightgray];',
    );
  }

  // Create nodes for all states with coloring
  for (var state in machine.states) {
    var stateId = "S${state.id}";
    String label = "S${state.id}";

    // Check if accept state
    bool isAcceptState = false;
    for (var action in state.actions) {
      if (action is AcceptAction) {
        isAcceptState = true;
        break;
      }
    }

    var shape = isAcceptState ? "doublecircle" : "circle";

    // Determine coloring
    String fillColor = "white";
    String borderColor = "black";
    String penWidth = "1";
    String fontColor = "black";

    // Check if this state has any active actions
    bool hasActiveActions = activeActionMap.any((entry) => entry.$1 == state.id);

    if (currentStates.contains(state.id)) {
      // RED for current states - brightest
      fillColor = "#ff6b6b";
      borderColor = "#c92a2a";
      penWidth = "4";
      fontColor = "white";
    } else if (hasActiveActions) {
      // RED for states with active actions (like inferred entry states)
      fillColor = "#ff6b6b";
      borderColor = "#c92a2a";
      penWidth = "4";
      fontColor = "white";
    } else if (nextStates.contains(state.id)) {
      // GREEN for next states
      fillColor = "#51cf66";
      borderColor = "#2b8a3e";
      penWidth = "2";
      fontColor = "white";
    }

    buffer.writeln(
      '  "$stateId" [shape=$shape, label="$label", style=filled, fillcolor="$fillColor", '
      'color="$borderColor", penwidth=$penWidth, fontcolor="$fontColor"];',
    );
  }

  // Start edge
  var startState = "S${machine.startState.id}";
  buffer.writeln('  "__start__" -> "$startState" [label="start"];');

  // Create edges for all transitions with action-specific styling
  for (var state in machine.states) {
    var fromStateId = "S${state.id}";
    bool isActionActive(String actionType) => activeActionMap.contains((state.id, actionType));

    for (var action in state.actions) {
      // Determine edge styling based on action type and whether it's active
      String edgeColor = "black";
      String edgeWidth = "1";
      String edgeStyle = "solid";
      String fontColor = "black";

      if (action is TokenAction) {
        var toStateId = "S${action.nextState.id}";
        var isActive = isActionActive("Token");

        // Check if this token action was successful or rejected
        var tokenActions = activeActions
            .where((a) => a.fromStateId == state.id && a.actionType == "Token")
            .toList();
        var isSuccessful = tokenActions.isNotEmpty && tokenActions.first.isSuccessful;

        if (isActive) {
          if (isSuccessful) {
            edgeColor = "#2b8a3e"; // Dark green for successful tokens
            edgeWidth = "4";
            fontColor = "#2b8a3e";
            edgeStyle = "solid";
          } else {
            edgeColor = "#c92a2a"; // Dark red for rejected tokens
            edgeWidth = "4";
            fontColor = "#c92a2a";
            edgeStyle = "dashed"; // Dashed for rejected
          }
        }
        buffer.writeln(
          '  "$fromStateId" -> "$toStateId" [label="token ${_dotEscape(action.choice.toString())}", '
          'color="$edgeColor", penwidth=$edgeWidth, style=$edgeStyle, fontcolor="$fontColor"];',
        );
      } else if (action is CallAction) {
        var toStateId = "S${action.returnState.id}";
        var ruleDisplay = action.minPrecedenceLevel != null
            ? "${action.ruleSymbol}^${action.minPrecedenceLevel}"
            : action.ruleSymbol;
        var isActive = isActionActive("Call");
        if (isActive) {
          edgeColor = "#cc5de8"; // Purple for active calls
          edgeWidth = "4";
        } else {
          edgeColor = "#d4a5d9"; // Very light purple for inactive
          edgeWidth = "1";
        }
        buffer.writeln(
          '  "$fromStateId" -> "$toStateId" [label="call $ruleDisplay", '
          'style=bold, color="$edgeColor", penwidth=$edgeWidth, fontcolor="$edgeColor"];',
        );
      } else if (action is TailCallAction) {
        var ruleDisplay = action.minPrecedenceLevel != null
            ? "${action.ruleSymbol}^${action.minPrecedenceLevel}"
            : action.ruleSymbol;
        var isActive = isActionActive("TailCall");
        if (isActive) {
          edgeColor = "#cc5de8";
          edgeWidth = "4";
        } else {
          edgeColor = "#d4a5d9";
          edgeWidth = "1";
        }
        buffer.writeln(
          '  "$fromStateId" -> "$fromStateId" [label="tail call $ruleDisplay", '
          'style=bold, color="$edgeColor", penwidth=$edgeWidth, fontcolor="$edgeColor"];',
        );
      } else if (action is ReturnAction) {
        var returnNodeId = "__return_${action.ruleSymbol}__";
        var labelStr = (machine.grammar.registry[action.ruleSymbol]! as Rule).name as String;
        if (action.precedenceLevel != null) {
          labelStr = "$labelStr (prec: ${action.precedenceLevel})";
        }
        var isActive = isActionActive("Return");
        if (isActive) {
          edgeColor = "#1971c2"; // Blue for active returns
          edgeWidth = "4";
        } else {
          edgeColor = "#b5d3f0"; // Light blue for inactive
          edgeWidth = "1";
        }
        buffer.writeln(
          '  "$fromStateId" -> "$returnNodeId" [label="return $labelStr", '
          'style=dashed, color="$edgeColor", penwidth=$edgeWidth, fontcolor="$edgeColor"];',
        );
      } else if (action is AcceptAction) {
        var isActive = isActionActive("Accept");
        if (isActive) {
          buffer.writeln(
            '  "$fromStateId" -> "__accept__" [label="accept", color="#ff6b6b", penwidth=4];',
          );
        } else {
          buffer.writeln(
            '  "$fromStateId" -> "__accept__" [label="accept", color="#d4d4d4", penwidth=1];',
          );
        }
      } else if (action is BoundaryAction) {
        var toStateId = "S${action.nextState.id}";
        var kindStr = action.kind == BoundaryKind.start ? "start" : "eof";
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="boundary $kindStr"];');
      } else if (action is LabelStartAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="label start ${action.name}"];');
      } else if (action is LabelEndAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln('  "$fromStateId" -> "$toStateId" [label="label end ${action.name}"];');
      } else if (action is PredicateAction) {
        var toStateId = "S${action.nextState.id}";
        var pred = action.isAnd ? "AND" : "NOT";
        buffer.writeln(
          '  "$fromStateId" -> "$toStateId" [label="$pred ${_dotEscape(action.symbol.toString())}", '
          "style=dashed, color=seagreen4];",
        );
      } else if (action is ConjunctionAction) {
        var toStateId = "S${action.nextState.id}";
        buffer.writeln(
          '  "$fromStateId" -> "$toStateId" [label="Conj ${_dotEscape(action.leftSymbol.toString())} & ${_dotEscape(action.rightSymbol.toString())}"];',
        );
      }
    }
  }

  // Add legend
  buffer.writeln();
  buffer.writeln("  { rank=sink; legend [shape=none, margin=0, label=<");
  buffer.writeln('    <TABLE BORDER="1" CELLBORDER="0" CELLSPACING="3">');
  buffer.writeln('      <TR><TD COLSPAN="2"><B>Legend</B></TD></TR>');
  buffer.writeln("      <TR>");
  buffer.writeln(
    '        <TD><TABLE BORDER="1" BGCOLOR="#ff6b6b"><TR><TD WIDTH="20"></TD></TR></TABLE></TD>',
  );
  buffer.writeln("        <TD><B>Current State</B> (being processed)</TD>");
  buffer.writeln("      </TR>");
  buffer.writeln("      <TR>");
  buffer.writeln(
    '        <TD><TABLE BORDER="1" BGCOLOR="#51cf66"><TR><TD WIDTH="20"></TD></TR></TABLE></TD>',
  );
  buffer.writeln("        <TD><B>Next State</B> (active)</TD>");
  buffer.writeln("      </TR>");
  buffer.writeln("      <TR>");
  buffer.writeln(
    '        <TD><TABLE BORDER="1" BGCOLOR="white"><TR><TD WIDTH="20"></TD></TR></TABLE></TD>',
  );
  buffer.writeln("        <TD><B>Inactive State</B></TD>");
  buffer.writeln("      </TR>");
  buffer.writeln('      <TR><TD COLSPAN="2"></TD></TR>');
  buffer.writeln(
    '      <TR><TD><B style="color:#2b8a3e">━ ━ ━</B></TD><TD>Token ✓ Matched (solid green)</TD></TR>',
  );
  buffer.writeln(
    '      <TR><TD><B style="color:#c92a2a">~ ~ ~</B></TD><TD>Token ✗ Rejected (dashed red)</TD></TR>',
  );
  buffer.writeln(
    '      <TR><TD><B style="color:#cc5de8">━ ━ ━</B></TD><TD>Call/TailCall (executed)</TD></TR>',
  );
  buffer.writeln(
    '      <TR><TD><B style="color:#1971c2">~~ ~~</B></TD><TD>Return (executed)</TD></TR>',
  );
  buffer.writeln(
    '      <TR><TD colspan="2"><B style="color:#d4d4d4">Light gray</B> = Not executed this step</TD></TR>',
  );
  buffer.writeln("    </TABLE>");
  buffer.writeln("  >]; }");

  buffer.writeln("}");
  return buffer.toString();
}

String _dotEscape(String value) {
  var out = StringBuffer();
  for (var rune in value.runes) {
    switch (rune) {
      case 0x5C: // \
        out.write(r"\\");
      case 0x22: // "
        out.write(r'\"');
      case 0x0A: // newline
        out.write(r"\n");
      case 0x0D: // carriage return
        out.write(r"\r");
      case 0x09: // tab
        out.write(r"\t");
      default:
        out.write(String.fromCharCode(rune));
    }
  }
  return out.toString();
}

void main() async {
  var traceFile = File("another.log");
  if (!traceFile.existsSync()) {
    print("❌ Error: another.log not found");
    print("Run: dart bin/glush.dart first");
    exit(1);
  }

  print("📖 Reading trace log...");
  var logContent = await traceFile.readAsString();

  // Load the grammar and create parser
  const grammar = """
  S = [0-9]+ [0-9]
""";
  var parser = grammar.toSMParser();

  print("🔍 Parsing trace data...");
  var traceData = parseTraceLog(logContent, parser.stateMachine);

  // Create output directory
  var outputDir = Directory("trace_graphs");
  if (outputDir.existsSync()) {
    outputDir.deleteSync(recursive: true);
  }
  outputDir.createSync(recursive: true);

  print("💾 Generating colored DOT graphs...");
  print("");

  var stepNum = 1;
  for (var entry in traceData.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
    var position = entry.key;
    var data = entry.value;

    var dotContent = generateColoredDot(
      parser.stateMachine,
      data.processedStates,
      data.nextStates,
      data.activeActions,
      data.token,
      position,
      stepNum,
    );

    var filename =
        'step_${stepNum.toString().padLeft(3, '0')}_pos_${position}_token_${data.token}.dot';
    var file = File("${outputDir.path}/$filename");
    await file.writeAsString(dotContent);

    var currentStr = data.processedStates.isEmpty
        ? "none"
        : data.processedStates.map((s) => "S$s").join(", ");
    var nextStr = data.nextStates.isEmpty ? "none" : data.nextStates.map((s) => "S$s").join(", ");

    var actionsStr = data.activeActions.isEmpty
        ? "none"
        : data.activeActions.map((a) => a.actionType).toSet().join(", ");

    print(
      '  ✓ Step $stepNum: Pos $position, Token "${data.token}" | '
      "Current: [$currentStr] | Next: [$nextStr] | Actions: [$actionsStr]",
    );

    stepNum++;
  }

  print("");
  print("✨ Done! Generated ${traceData.length} graphs in trace_graphs/");
  print("");
  print("📊 Visualization options:");
  print("   1. Online: https://dreampuf.github.io/GraphvizOnline/");
  print('   2. PNG: cd trace_graphs && for %f in (*.dot) do dot -Tpng "%f" -o "%~nf.png"');
}
