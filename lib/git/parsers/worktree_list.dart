/// Parser for `git worktree list --porcelain -z` output.
///
/// Pure Dart, no dart:io — see git-worktree(1), "PORCELAIN FORMAT". With
/// `-z`, every attribute line (including the blank line that separates one
/// worktree record from the next) is NUL-terminated rather than
/// newline-terminated, so a record boundary shows up as an empty token when
/// the whole stream is split on `\x00`.
library;

class WorktreeInfo {
  final String path;

  /// Short branch name (`refs/heads/<name>` → `<name>`); null when detached
  /// or bare.
  final String? branch;

  /// HEAD commit id; null for a bare worktree (no `HEAD` attribute at all).
  final String? headOid;

  final bool bare;
  final bool detached;
  final bool locked;
  final bool prunable;

  const WorktreeInfo({
    required this.path,
    this.branch,
    this.headOid,
    this.bare = false,
    this.detached = false,
    this.locked = false,
    this.prunable = false,
  });
}

/// Parses `git worktree list --porcelain -z` output into [WorktreeInfo]s, in
/// the order git lists them (the main worktree first).
List<WorktreeInfo> parseWorktreeListZ(String zOutput) {
  final infos = <WorktreeInfo>[];

  var path = '';
  String? branch;
  String? headOid;
  var bare = false;
  var detached = false;
  var locked = false;
  var prunable = false;
  var hasAttrs = false;

  void flush() {
    if (!hasAttrs) return; // an empty record — stray/trailing separator
    infos.add(WorktreeInfo(
      path: path,
      branch: branch,
      headOid: headOid,
      bare: bare,
      detached: detached,
      locked: locked,
      prunable: prunable,
    ));
    path = '';
    branch = null;
    headOid = null;
    bare = false;
    detached = false;
    locked = false;
    prunable = false;
    hasAttrs = false;
  }

  for (final token in zOutput.split('\x00')) {
    if (token.isEmpty) {
      // The blank line ending a record (or a stray/trailing NUL).
      flush();
      continue;
    }
    hasAttrs = true;
    final sp = token.indexOf(' ');
    final key = sp < 0 ? token : token.substring(0, sp);
    final value = sp < 0 ? '' : token.substring(sp + 1);
    switch (key) {
      case 'worktree':
        path = value;
      case 'HEAD':
        headOid = value;
      case 'branch':
        branch = value.startsWith('refs/heads/')
            ? value.substring('refs/heads/'.length)
            : value;
      case 'bare':
        bare = true;
      case 'detached':
        detached = true;
      case 'locked':
        locked = true;
      case 'prunable':
        prunable = true;
      default:
        break; // unknown attribute — ignore defensively
    }
  }
  flush(); // in case the output doesn't end with the usual trailing NUL

  return infos;
}
