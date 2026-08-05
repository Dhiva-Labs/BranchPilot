import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves [repoPath]'s git directory. `.git` is usually a directory, but
/// may be a file containing a `gitdir: <path>` indirection (linked
/// worktrees, submodules) — shared by [RepoWatcher] and the op-state
/// detection below so the indirection logic lives in exactly one place.
Future<String> resolveGitDir(String repoPath) async {
  final dotGit = p.join(repoPath, '.git');
  if (await FileSystemEntity.type(dotGit) == FileSystemEntityType.file) {
    final content = await File(dotGit).readAsString();
    final match = RegExp(r'gitdir:\s*(.+)').firstMatch(content);
    if (match != null) {
      final target = match.group(1)!.trim();
      return p.isAbsolute(target)
          ? target
          : p.normalize(p.join(repoPath, target));
    }
  }
  return dotGit;
}

/// A multi-step git operation left in progress (interrupted by a conflict,
/// or awaiting `--continue`).
enum RepoOpState { none, merging, rebasing, cherryPicking, reverting }

/// Detects the current in-progress operation from marker files/directories
/// under the git directory. When more than one marker is present at once
/// (e.g. an interactive rebase implemented as a sequence of cherry-picks can
/// leave both a rebase directory and CHERRY_PICK_HEAD around), rebasing wins,
/// then merging, then cherry-picking, then reverting.
Future<RepoOpState> detectOpState(String repoPath) async {
  final gitDir = await resolveGitDir(repoPath);

  Future<bool> exists(String rel) async =>
      await FileSystemEntity.type(p.join(gitDir, rel)) !=
      FileSystemEntityType.notFound;

  if (await exists('rebase-merge') || await exists('rebase-apply')) {
    return RepoOpState.rebasing;
  }
  if (await exists('MERGE_HEAD')) return RepoOpState.merging;
  if (await exists('CHERRY_PICK_HEAD')) return RepoOpState.cherryPicking;
  if (await exists('REVERT_HEAD')) return RepoOpState.reverting;
  return RepoOpState.none;
}
