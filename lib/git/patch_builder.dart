/// Reconstructs minimal valid patches from parsed diffs, for hunk-level
/// staging via `git apply --cached -` (and unstaging via `--cached -R`).
library;

import 'parsers/unified_diff.dart';

/// Builds a unified patch containing only [selected] hunks of [file].
///
/// Hunk bodies are emitted byte-for-byte as parsed (CR and no-newline
/// markers included). The new-side start positions are recomputed as if the
/// selected hunks were the only changes, keeping the patch self-consistent:
/// `newStart = oldStart + Σ(newCount − oldCount)` over the selected hunks
/// before it — with the usual unified-diff special cases for pure-insertion
/// (`oldCount == 0`: position is "after old line N", so +1) and
/// whole-content-deletion (`newCount == 0`: new side starts at 0).
String buildPatch(FileDiff file, List<DiffHunk> selected) {
  assert(selected.isNotEmpty, 'buildPatch needs at least one hunk');
  final hunks = [...selected]..sort((a, b) => a.oldStart.compareTo(b.oldStart));
  final buf = StringBuffer();
  final oldPath = file.oldPath;
  final newPath = file.newPath;
  buf.writeln(oldPath == null ? '--- /dev/null' : '--- a/$oldPath');
  buf.writeln(newPath == null ? '+++ /dev/null' : '+++ b/$newPath');
  var delta = 0;
  for (final h in hunks) {
    final int newStart;
    if (h.oldCount == 0) {
      newStart = h.oldStart + delta + 1;
    } else if (h.newCount == 0) {
      final v = h.oldStart + delta - 1;
      newStart = v < 0 ? 0 : v;
    } else {
      newStart = h.oldStart + delta;
    }
    buf.writeln('@@ -${h.oldStart},${h.oldCount} +$newStart,${h.newCount} @@'
        '${h.heading.isEmpty ? '' : ' ${h.heading}'}');
    for (final l in h.lines) {
      buf.writeln(l.raw);
    }
    delta += h.newCount - h.oldCount;
  }
  return buf.toString();
}
