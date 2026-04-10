import "package:glush/src/core/list.dart";
import "package:glush/src/core/mark.dart";
import "package:glush/src/core/patterns.dart";
import "package:glush/src/core/profiling.dart";
import "package:meta/meta.dart";

final class LabelCaptureFrame {
  LabelCaptureFrame(this.name, this.startPosition);

  final String name;
  final int startPosition;
}

final class LabelCaptureWalker {
  LabelCaptureWalker(this.target);

  final String target;
  CaptureValue? best;

  // This walker is a tiny explicit DFS over the persistent mark forest.
  // It keeps the capture logic reusable without the hidden state that came
  // from the earlier nested local closures.
  void walk(GlushList<Mark> node, List<LabelCaptureFrame> active) {
    switch (node) {
      case EmptyList<Mark>():
        return;
      case Push<Mark>(:var parent, :var data):
        walk(parent, active);
        visitMark(data, active);
      case Concat<Mark>(:var left, :var right):
        walk(left, active);
        walk(right, active);
      case Conjunction<Mark>(:var left, :var right):
        // Parallel marks occur at same span, so both are explored with same context
        walk(left, active);
        walk(right, active);
      case BranchedList<Mark>(:var left, :var right):
        var rest = [...active];
        walk(left, rest);
        if (right != null) {
          walk(right, rest);
        }
    }
  }

  void visitMark(Mark mark, List<LabelCaptureFrame> active) {
    switch (mark) {
      case LabelStartMark(:var name, :var position):
        // Only the requested label name starts a capture frame.
        if (name == target) {
          active.add(LabelCaptureFrame(name, position));
        }
      case LabelEndMark(:var name):
        if (name == target) {
          for (var i = active.length - 1; i >= 0; i--) {
            if (active[i].name == name) {
              var frame = active.removeAt(i);
              consider(CaptureValue(frame.startPosition, mark.position, ""));
              break;
            }
          }
        }
      case ConjunctionMark(:var left, :var right):
        // Ambiguous branches need isolated active stacks, otherwise captures
        // from one derivation would leak into another.
        walk(left.evaluate(), [...active]);
        walk(right.evaluate(), [...active]);
      default:
        break;
    }
  }

  void consider(CaptureValue? candidate) {
    if (candidate == null) {
      return;
    }
    if (best == null || candidate.startPosition < best!.startPosition) {
      best = candidate;
    }
  }
}

String _captureSignatureFromMap(Map<String, CaptureValue?> captures) {
  if (captures.isEmpty) {
    return "";
  }
  var entries = captures.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  var buffer = StringBuffer();
  for (var entry in entries) {
    buffer.write(entry.key);
    buffer.write("=");
    var value = entry.value;
    if (value == null) {
      buffer.write("null");
    } else {
      buffer
        ..write(value.startPosition)
        ..write(":")
        ..write(value.endPosition)
        ..write(":")
        ..write(value.value.length)
        ..write(":")
        ..write(value.value);
    }
    buffer.write(";");
  }
  return buffer.toString();
}

@immutable
final class CaptureBindings {
  const CaptureBindings._(this.parent, this.delta);
  const CaptureBindings.empty() : parent = null, delta = null;

  final CaptureBindings? parent;
  final Map<String, CaptureValue?>? delta;

  bool get isEmpty => (delta == null || delta!.isEmpty) && (parent == null || parent!.isEmpty);

  CaptureValue? operator [](String key) {
    if (delta case var current? when current.containsKey(key)) {
      return current[key];
    }
    return parent?[key];
  }

  bool containsKey(String key) =>
      (delta?.containsKey(key) ?? false) || (parent?.containsKey(key) ?? false);

  CaptureBindings overlay(CaptureBindings overlay) {
    if (overlay.isEmpty) {
      return this;
    }
    if (isEmpty) {
      return overlay;
    }
    return CaptureBindings._(this, overlay.toMap());
  }

  static final Expando<Map<String, CaptureValue?>> _maps = Expando();
  Map<String, CaptureValue?> toMap() {
    var cached = _maps[this];
    if (cached != null) {
      return cached;
    }

    Map<String, CaptureValue?> computed;
    if (parent == null) {
      computed = delta == null || delta!.isEmpty
          ? const <String, CaptureValue?>{}
          : Map.unmodifiable(delta!);
    } else {
      var merged = <String, CaptureValue?>{...parent!.toMap()};
      if (delta != null && delta!.isNotEmpty) {
        merged.addAll(delta!);
      }
      computed = Map.unmodifiable(merged);
    }
    _maps[this] = computed;
    GlushProfiler.increment("parser.bindings.map_cache_assign");
    return computed;
  }

  static final Expando<String> _signatures = Expando();
  String get signature {
    var sig = _signatures[this];
    if (sig != null) {
      return sig;
    }
    sig = _captureSignatureFromMap(toMap());
    _signatures[this] = sig;
    GlushProfiler.increment("parser.bindings.signature_cache_assign");
    return sig;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CaptureBindings && hashCode == other.hashCode && signature == other.signature;

  static final Expando<int> _hashes = Expando();
  @override
  int get hashCode {
    var h = _hashes[this];
    if (h != null) {
      return h;
    }
    return _hashes[this] = signature.hashCode;
  }
}
