import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../git/git_cli.dart';
import '../git/parsers/unified_diff.dart';
import '../git/patch_builder.dart';
import 'providers.dart';

/// Which section of the status panel a diff is being viewed from. The same
/// path can exist in more than one section at once (a partially-staged file
/// is both staged and unstaged), so this is part of the selection identity,
/// not just a display label.
enum DiffPane { unstaged, staged, untracked }

/// The file (and section) currently shown in the center diff pane, if any.
typedef SelectedFile = ({String path, DiffPane pane});

/// Tracks which file/section is open in the diff view for one repo.
///
/// Riverpod families key on `==`, and records compare structurally, so this
/// and [FileDiffKey] below get correct provider identity for free.
class SelectedFileNotifier
    extends AutoDisposeFamilyNotifier<SelectedFile?, String> {
  @override
  SelectedFile? build(String arg) {
    // Guard against showing a stale selection: if the file we're viewing no
    // longer has a change in that section (e.g. its last hunk was staged, or
    // a staged file got fully unstaged), there is nothing left to show there
    // — drop the selection so the UI falls back to the commit graph instead
    // of a diff for a change that no longer exists in that section.
    ref.listen(repoStatusProvider(arg), (previous, next) {
      final sel = state;
      if (sel == null) return;
      final snapshot = next.valueOrNull;
      if (snapshot == null) return;
      final stillInPane = switch (sel.pane) {
            DiffPane.staged => snapshot.staged,
            DiffPane.unstaged => snapshot.unstaged,
            DiffPane.untracked => snapshot.untracked,
          }
          .any((e) => e.path == sel.path);
      if (!stillInPane) state = null;
    });
    return null;
  }

  void select(String path, DiffPane pane) => state = (path: path, pane: pane);

  void clear() => state = null;
}

final selectedFileProvider = NotifierProvider.autoDispose
    .family<SelectedFileNotifier, SelectedFile?, String>(
        SelectedFileNotifier.new);

/// Key for [fileDiffProvider]: one file's diff, in one section, of one repo.
typedef FileDiffKey = ({String repo, String path, DiffPane pane});

/// Loads the parsed diff for a single file in a single section. Re-fetches
/// whenever the repo's status snapshot changes (stage/unstage, external
/// edits, ...).
final fileDiffProvider =
    FutureProvider.autoDispose.family<List<FileDiff>, FileDiffKey>(
  (ref, arg) async {
    ref.watch(repoStatusProvider(arg.repo));
    final git = GitCli(arg.repo);

    switch (arg.pane) {
      case DiffPane.unstaged:
        final r =
            await git.run(['diff', '-U3', '--no-color', '--', arg.path]);
        return parseUnifiedDiff(r.stdout);
      case DiffPane.staged:
        final r = await git.run(
            ['diff', '-U3', '--no-color', '--cached', '--', arg.path]);
        return parseUnifiedDiff(r.stdout);
      case DiffPane.untracked:
        final abs = p.join(arg.repo, arg.path);
        final args = [
          'diff', '--no-index', '-U3', '--no-color', '--', '/dev/null', abs,
        ];
        final r = await git.run(args, check: false);
        // --no-index: 0 = identical (only for a genuinely empty file
        // compared with nothing), 1 = differences found, >=2 = real error.
        if (r.exitCode >= 2) {
          throw GitException(args.join(' '), r.exitCode, r.stderr);
        }
        return [
          for (final f in parseUnifiedDiff(r.stdout)) _asUntracked(f, arg.path),
        ];
    }
  },
);

/// `git diff --no-index` diffs two filesystem paths directly, so the parsed
/// paths come out absolute-ish (rooted at the temp-file side) rather than
/// repo-relative. Untracked files also never have an "old" side.
FileDiff _asUntracked(FileDiff f, String relPath) => FileDiff(
      oldPath: null,
      newPath: relPath,
      isBinary: f.isBinary,
      isNew: f.isNew,
      isDeleted: f.isDeleted,
      isRename: f.isRename,
      isCopy: f.isCopy,
      similarity: f.similarity,
      oldMode: f.oldMode,
      newMode: f.newMode,
      hunks: f.hunks,
    );

/// Working-tree mutations invoked from the UI: stage/unstage a whole file,
/// everything, or a single hunk. Every operation refreshes
/// [repoStatusProvider] on success; git failures propagate to the caller so
/// the UI can surface them (e.g. in a SnackBar).
class WorkingTreeOps {
  final String repo;
  final WidgetRef ref;

  WorkingTreeOps(this.repo, this.ref);

  GitCli get _git => GitCli(repo);

  Future<void> _refresh() =>
      ref.read(repoStatusProvider(repo).notifier).refresh();

  Future<void> stageFile(String path) async {
    await _git.run(['add', '--', path]);
    await _refresh();
  }

  /// `git reset` rather than `git restore --staged`: reset also works before
  /// the first commit (unborn HEAD), where restore fails to resolve HEAD.
  /// For a staged rename the index holds delete(old)+add(new), so both paths
  /// must be reset — pass [origPath] for rename entries.
  Future<void> unstageFile(String path, {String? origPath}) async {
    await _git.run([
      'reset', '-q', '--', path,
      if (origPath != null && origPath != path) origPath,
    ]);
    await _refresh();
  }

  Future<void> stageAll() async {
    await _git.run(['add', '-A']);
    await _refresh();
  }

  Future<void> unstageAll() async {
    await _git.run(['reset', '-q']);
    await _refresh();
  }

  Future<void> stageHunk(FileDiff file, DiffHunk hunk) async {
    await _git.run(['apply', '--cached', '-'],
        stdin: utf8.encode(buildPatch(file, [hunk])));
    await _refresh();
  }

  Future<void> unstageHunk(FileDiff cachedFile, DiffHunk hunk) async {
    await _git.run(['apply', '--cached', '-R', '-'],
        stdin: utf8.encode(buildPatch(cachedFile, [hunk])));
    await _refresh();
  }
}
