/// Parser for `git stash list -z --format=%gd%x1f%gs` output.
///
/// Pure Dart, no dart:io. With `-z`, records are NUL-separated; each record
/// has exactly two fields split on 0x1f: the reflog selector (`%gd`, e.g.
/// `stash@{0}`) and the reflog subject (`%gs`, e.g. `WIP on main: 1234567
/// message` for a plain `git stash push`, or `On main: message` when pushed
/// with `-m`).
library;

class StashItem {
  /// Position in the stash list (0 = most recent).
  final int index;

  /// The full `%gs` reflog subject, kept as-is (`On <branch>: <msg>` or
  /// `WIP on <branch>: <short-oid> <msg>`) — good enough for display without
  /// needing to distinguish the two shapes.
  final String message;

  /// The raw ref (`stash@{N}`) every stash git command takes.
  final String rawRef;

  const StashItem({
    required this.index,
    required this.message,
    required this.rawRef,
  });
}

final _stashRefIndex = RegExp(r'^stash@\{(\d+)\}$');

/// Parses `git stash list -z --format=%gd%x1f%gs` output into [StashItem]s,
/// in git's own list order (most-recent-first).
List<StashItem> parseStashListZ(String zOutput) {
  final items = <StashItem>[];
  for (final record in zOutput.split('\x00')) {
    if (record.isEmpty) continue; // trailing NUL, or empty input
    final sep = record.indexOf('\x1f');
    if (sep < 0) continue; // malformed — skip defensively
    final rawRef = record.substring(0, sep);
    final message = record.substring(sep + 1);
    final m = _stashRefIndex.firstMatch(rawRef);
    final index = m != null ? int.parse(m.group(1)!) : items.length;
    items.add(StashItem(index: index, message: message, rawRef: rawRef));
  }
  return items;
}
