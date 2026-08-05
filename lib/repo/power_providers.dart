import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_cli.dart';
import '../git/git_dirs.dart';
import '../git/parsers/worktree_list.dart';
import 'providers.dart';

export '../git/parsers/worktree_list.dart' show WorktreeInfo;

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

/// One tag (`refs/tags/*`), as listed for the left panel.
class TagItem {
  final String name;
  final String shortOid;
  final bool annotated;

  /// The annotated tag's message subject line; null for a lightweight tag
  /// (which has no tag object of its own to carry a message).
  final String? message;

  const TagItem({
    required this.name,
    required this.shortOid,
    required this.annotated,
    this.message,
  });
}

/// `--format=` string used by [tagsProvider] (see [parseForEachRefTags]).
/// `%(objecttype)` is `tag` for an annotated tag (the ref points at a tag
/// object) or `commit` for a lightweight one (the ref points straight at the
/// commit) — that's what distinguishes the two, not anything about the name.
const tagsForEachRefFormat = '--format=%(refname:short)%00%(objectname:short)'
    '%00%(objecttype)%00%(contents:subject)';

/// Parses `git for-each-ref refs/tags $tagsForEachRefFormat` output (one ref
/// per line, NUL-separated fields) into [TagItem]s. A standalone function
/// (rather than inlined in the provider) so it's directly unit-testable
/// against real git output — same reasoning as branch_providers.dart's
/// `parseForEachRefBranches`.
List<TagItem> parseForEachRefTags(String stdout) {
  final items = <TagItem>[];
  for (final line in stdout.split('\n')) {
    if (!line.contains('\x00')) continue; // blank trailing line
    final f = line.split('\x00');
    if (f.length < 4) continue; // malformed — skip defensively
    final annotated = f[2] == 'tag';
    items.add(TagItem(
      name: f[0],
      shortOid: f[1],
      annotated: annotated,
      message: annotated ? f.sublist(3).join('\x00') : null,
    ));
  }
  return items;
}

/// Tag listing for the left panel. Refetches whenever the status snapshot
/// changes — tag creation/deletion from the graph's context menu doesn't
/// otherwise touch the working tree, but the status watcher's git-dir
/// watch still picks up the new/removed ref.
final tagsProvider = FutureProvider.autoDispose.family<List<TagItem>, String>(
    (ref, repo) async {
  ref.watch(repoStatusProvider(repo));
  final r = await GitCli(repo)
      .run(['for-each-ref', 'refs/tags', tagsForEachRefFormat]);
  return parseForEachRefTags(r.stdout);
});

// ---------------------------------------------------------------------------
// Worktrees
// ---------------------------------------------------------------------------

/// Worktree listing for the left panel (main worktree first, as git lists
/// them). Refetches whenever the status snapshot changes.
final worktreesProvider = FutureProvider.autoDispose
    .family<List<WorktreeInfo>, String>((ref, repo) async {
  ref.watch(repoStatusProvider(repo));
  final r =
      await GitCli(repo).run(['worktree', 'list', '--porcelain', '-z']);
  return parseWorktreeListZ(r.stdout);
});

// ---------------------------------------------------------------------------
// Per-file history
// ---------------------------------------------------------------------------

/// One commit touching a particular file, for the file-history dialog.
class FileHistoryEntry {
  final String hash;
  final String authorName;
  final DateTime date;
  final String subject;

  const FileHistoryEntry({
    required this.hash,
    required this.authorName,
    required this.date,
    required this.subject,
  });

  String get shortHash => hash.length >= 7 ? hash.substring(0, 7) : hash;
}

/// `--pretty=format:` string used by [fileHistoryProvider].
const fileHistoryLogFormat = '%H%x1f%an%x1f%at%x1f%s';

/// Parses `git log --follow -z --pretty=format:$fileHistoryLogFormat -- path`
/// output into [FileHistoryEntry]s, newest first (git's default log order).
List<FileHistoryEntry> parseFileHistoryZ(String zOutput) {
  final entries = <FileHistoryEntry>[];
  for (final token in zOutput.split('\x00')) {
    // Defensive, matching rebase_providers.dart's candidate-log parsing: some
    // git versions/configurations prefix all but the first record with a
    // newline under `format:` + `-z`.
    final t = token.startsWith('\n') ? token.substring(1) : token;
    if (t.isEmpty) continue;
    final f = t.split('\x1f');
    if (f.length < 4) continue; // malformed — skip defensively
    entries.add(FileHistoryEntry(
      hash: f[0],
      authorName: f[1],
      date: DateTime.fromMillisecondsSinceEpoch(
          (int.tryParse(f[2]) ?? 0) * 1000),
      subject: f.sublist(3).join('\x1f'),
    ));
  }
  return entries;
}

/// Commit history for one file, following renames. No status watch — this
/// is loaded once per file-history dialog and a historical file's past
/// commits don't change while it's open (same reasoning as
/// commit_providers.dart's `commitFileDiffProvider`).
final fileHistoryProvider = FutureProvider.autoDispose
    .family<List<FileHistoryEntry>, ({String repo, String path})>(
        (ref, arg) async {
  final r = await GitCli(arg.repo).run([
    'log',
    '--follow',
    '-z',
    '--pretty=format:$fileHistoryLogFormat',
    '--',
    arg.path,
  ]);
  return parseFileHistoryZ(r.stdout);
});

// ---------------------------------------------------------------------------
// Power ops
// ---------------------------------------------------------------------------

/// Tag / cherry-pick / revert / reset / worktree operations invoked from the
/// graph's context menu, the left panel, and the status panel's sequencer
/// banner. Every operation refreshes [repoStatusProvider] on success (or,
/// for the ones that can pause on a conflict, regardless of outcome); git
/// failures propagate as [GitException] to the caller so the UI can surface
/// them (e.g. in a SnackBar) — except where a [GitResult] is returned
/// instead, so the caller can distinguish an expected conflict pause from a
/// real failure without an exception in the way.
class PowerOps {
  final String repo;
  final WidgetRef ref;

  PowerOps(this.repo, this.ref);

  GitCli get _git => GitCli(repo);

  Future<void> _refresh() =>
      ref.read(repoStatusProvider(repo).notifier).refresh();

  /// Lightweight tag when [message] is null/empty; annotated otherwise.
  Future<void> createTag(String name, {String? onCommit, String? message}) async {
    final msg = message?.trim();
    if (msg == null || msg.isEmpty) {
      await _git.run(['tag', name, ?onCommit]);
    } else {
      await _git.run(['tag', '-a', name, '-m', msg, ?onCommit]);
    }
    await _refresh();
  }

  Future<void> deleteTag(String name) async {
    await _git.run(['tag', '-d', name]);
    await _refresh();
  }

  /// Returns the [GitResult] instead of throwing on a non-zero exit so the
  /// caller can distinguish a conflict (CHERRY_PICK_HEAD op state, resolved
  /// through the status panel's banner) from any other failure. The status
  /// snapshot is refreshed either way since a conflicted cherry-pick still
  /// changes the working tree.
  ///
  /// [mainline] is the 1-based parent index (`-m <n>`) git needs as a diff
  /// base when [hash] is a merge commit — without it, git refuses a merge
  /// outright with "commit … is a merge but no -m option was given."
  ///
  /// Must stay null for an ordinary (non-merge) commit, and note *why* that
  /// discipline can't be delegated to testing: git does NOT reject `-m 1` on
  /// a non-merge — it accepts it silently (parent 1 resolves to the commit's
  /// sole parent) and exits 0. Only `-m n` for n >= 2 errors, with
  /// "does not have parent n". So passing a mainline unconditionally would
  /// look green in tests while being wrong in principle; the guard has to be
  /// at the call site. `commit_graph_view.dart`'s `_runCherryPickOrRevert`
  /// supplies [mainline] only after checking `CommitRecord.isMerge`.
  /// Verified against git 2.43 — see test/git/merge_cherry_pick_test.dart.
  Future<GitResult> cherryPick(String hash, {int? mainline}) async {
    final result = await _git.run(
      ['cherry-pick', if (mainline != null) ...['-m', '$mainline'], hash],
      check: false,
    );
    await _refresh();
    return result;
  }

  /// Same conflict-vs-failure reasoning as [cherryPick]; see its doc comment
  /// for [mainline].
  Future<GitResult> revert(String hash, {int? mainline}) async {
    final result = await _git.run([
      'revert',
      '--no-edit',
      if (mainline != null) ...['-m', '$mainline'],
      hash,
    ], check: false);
    await _refresh();
    return result;
  }

  /// Concludes an in-progress cherry-pick or revert once conflicts are
  /// resolved. `GIT_EDITOR=true` accepts the prepared commit message instead
  /// of blocking on an interactive editor.
  Future<GitResult> continueSequencer(RepoOpState state) async {
    final args = state == RepoOpState.cherryPicking
        ? ['cherry-pick', '--continue']
        : ['revert', '--continue'];
    final result = await _git
        .run(args, check: false, environment: const {'GIT_EDITOR': 'true'});
    await _refresh();
    return result;
  }

  Future<void> abortSequencer(RepoOpState state) async {
    final args = state == RepoOpState.cherryPicking
        ? ['cherry-pick', '--abort']
        : ['revert', '--abort'];
    await _git.run(args);
    await _refresh();
  }

  Future<void> reset(String hash, {required String mode}) async {
    await _git.run(['reset', '--$mode', hash]);
    await _refresh();
  }

  Future<void> addWorktree(String path,
      {String? newBranch, String? checkoutExisting}) async {
    await _git.run([
      'worktree',
      'add',
      if (newBranch != null) ...['-b', newBranch],
      path,
      ?checkoutExisting,
    ]);
    await _refresh();
  }

  Future<void> removeWorktree(String path, {bool force = false}) async {
    await _git.run(['worktree', 'remove', if (force) '--force', path]);
    await _refresh();
  }
}
