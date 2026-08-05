/// Parser for `git status --porcelain=v2 --branch -z` output.
///
/// Pure Dart, no dart:io — see git-status(1), "Porcelain Format Version 2".
/// With `-z`, records are NUL-terminated and the rename record carries the
/// original path as a second NUL-terminated token.
library;

enum FileState {
  unmodified,
  modified,
  typeChanged,
  added,
  deleted,
  renamed,
  copied,
  unmerged,
  untracked,
  ignored,
}

FileState _stateOf(String c) => switch (c) {
      '.' => FileState.unmodified,
      'M' => FileState.modified,
      'T' => FileState.typeChanged,
      'A' => FileState.added,
      'D' => FileState.deleted,
      'R' => FileState.renamed,
      'C' => FileState.copied,
      'U' => FileState.unmerged,
      _ => FileState.unmodified,
    };

class StatusEntry {
  final String path;

  /// Rename/copy source path.
  final String? origPath;

  /// The raw two-character XY field, e.g. 'M.', '.M', 'R.', 'UU'.
  final String xy;

  /// Submodule field: `N...` for ordinary files, `S<c><m><u>` for submodules.
  final String sub;

  final bool unmerged;
  final bool untracked;
  final bool ignored;
  final int? renameScore;

  const StatusEntry({
    required this.path,
    this.origPath,
    required this.xy,
    this.sub = 'N...',
    this.unmerged = false,
    this.untracked = false,
    this.ignored = false,
    this.renameScore,
  });

  FileState get indexState => untracked
      ? FileState.untracked
      : ignored
          ? FileState.ignored
          : _stateOf(xy[0]);

  FileState get worktreeState => untracked
      ? FileState.untracked
      : ignored
          ? FileState.ignored
          : _stateOf(xy[1]);

  bool get hasStagedChange =>
      !untracked && !ignored && !unmerged && indexState != FileState.unmodified;

  bool get hasWorktreeChange =>
      !untracked &&
      !ignored &&
      !unmerged &&
      worktreeState != FileState.unmodified;

  bool get isSubmodule => sub.startsWith('S');
}

class BranchInfo {
  /// HEAD commit id; null while the branch is unborn (no commits yet).
  final String? oid;

  /// Branch name; null when HEAD is detached.
  final String? head;

  final String? upstream;
  final int? ahead;
  final int? behind;

  const BranchInfo({this.oid, this.head, this.upstream, this.ahead, this.behind});

  bool get detached => head == null;
  bool get initial => oid == null;
}

class StatusSnapshot {
  final BranchInfo branch;
  final List<StatusEntry> entries;

  const StatusSnapshot({required this.branch, required this.entries});

  List<StatusEntry> get conflicted =>
      entries.where((e) => e.unmerged).toList();
  List<StatusEntry> get staged =>
      entries.where((e) => e.hasStagedChange).toList();
  List<StatusEntry> get unstaged =>
      entries.where((e) => e.hasWorktreeChange).toList();
  List<StatusEntry> get untracked =>
      entries.where((e) => e.untracked).toList();

  bool get isClean => entries.isEmpty;
  bool get hasConflicts => entries.any((e) => e.unmerged);
}

StatusSnapshot parsePorcelainV2(String zOutput) {
  String? oid;
  String? head;
  String? upstream;
  int? ahead;
  int? behind;
  final entries = <StatusEntry>[];

  final tokens = zOutput.split('\x00');
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.isEmpty) continue;

    if (t.startsWith('# ')) {
      final body = t.substring(2);
      if (body.startsWith('branch.oid ')) {
        final v = body.substring('branch.oid '.length);
        oid = v == '(initial)' ? null : v;
      } else if (body.startsWith('branch.head ')) {
        final v = body.substring('branch.head '.length);
        head = v == '(detached)' ? null : v;
      } else if (body.startsWith('branch.upstream ')) {
        upstream = body.substring('branch.upstream '.length);
      } else if (body.startsWith('branch.ab ')) {
        for (final part in body.substring('branch.ab '.length).split(' ')) {
          if (part.startsWith('+')) ahead = int.tryParse(part.substring(1));
          if (part.startsWith('-')) behind = int.tryParse(part.substring(1));
        }
      }
      continue;
    }

    switch (t[0]) {
      // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
      case '1':
        final (f, path) = _fields(t, 8);
        entries.add(StatusEntry(path: path, xy: f[1], sub: f[2]));
      // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>NUL<origPath>
      case '2':
        final (f, path) = _fields(t, 9);
        final orig = ++i < tokens.length ? tokens[i] : '';
        entries.add(StatusEntry(
          path: path,
          origPath: orig,
          xy: f[1],
          sub: f[2],
          renameScore: int.tryParse(f[8].substring(1)),
        ));
      // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
      case 'u':
        final (f, path) = _fields(t, 10);
        entries.add(StatusEntry(path: path, xy: f[1], sub: f[2], unmerged: true));
      case '?':
        entries.add(
            StatusEntry(path: t.substring(2), xy: '??', untracked: true));
      case '!':
        entries.add(StatusEntry(path: t.substring(2), xy: '!!', ignored: true));
      default:
        break; // unknown record type — skip
    }
  }

  return StatusSnapshot(
    branch: BranchInfo(
        oid: oid, head: head, upstream: upstream, ahead: ahead, behind: behind),
    entries: entries,
  );
}

/// Splits [count] space-separated fields off the front of [s]; the remainder
/// (which may itself contain spaces — it's a path) is returned as the rest.
(List<String>, String) _fields(String s, int count) {
  final fields = <String>[];
  var rest = s;
  for (var i = 0; i < count; i++) {
    final sp = rest.indexOf(' ');
    if (sp < 0) return (fields..add(rest), '');
    fields.add(rest.substring(0, sp));
    rest = rest.substring(sp + 1);
  }
  return (fields, rest);
}
