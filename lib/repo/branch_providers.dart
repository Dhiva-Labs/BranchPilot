import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_cli.dart';
import '../git/git_dirs.dart';
import '../git/parsers/stash_list.dart';
import '../git/parsers/unified_diff.dart';
import 'providers.dart';

export '../git/git_dirs.dart' show RepoOpState;
export '../git/parsers/stash_list.dart' show StashItem;

/// One local branch (`refs/heads/*`), as listed for the left panel.
class BranchItem {
  final String name;
  final String shortOid;
  final bool isHead;
  final String? upstream;
  final int ahead;
  final int behind;

  /// True when an upstream is configured but its remote-tracking ref is
  /// gone (deleted upstream and pruned locally).
  final bool gone;

  final String subject;

  const BranchItem({
    required this.name,
    required this.shortOid,
    required this.isHead,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    this.gone = false,
    required this.subject,
  });
}

/// Parses one `upstream:track,nobracket` field: `''` (in sync or no
/// upstream), `'ahead N'`, `'behind N'`, `'ahead N, behind N'`, or `'gone'`.
({int ahead, int behind, bool gone}) _parseTrack(String track) {
  if (track.isEmpty) return (ahead: 0, behind: 0, gone: false);
  if (track == 'gone') return (ahead: 0, behind: 0, gone: true);
  var ahead = 0;
  var behind = 0;
  for (final part in track.split(', ')) {
    final aheadMatch = RegExp(r'^ahead (\d+)$').firstMatch(part);
    final behindMatch = RegExp(r'^behind (\d+)$').firstMatch(part);
    if (aheadMatch != null) ahead = int.parse(aheadMatch.group(1)!);
    if (behindMatch != null) behind = int.parse(behindMatch.group(1)!);
  }
  return (ahead: ahead, behind: behind, gone: false);
}

/// Local branch listing for the left panel. Refetches whenever the status
/// snapshot changes (checkout, commit, branch create/delete all move what
/// `for-each-ref` reports).
final branchesProvider = FutureProvider.autoDispose
    .family<List<BranchItem>, String>((ref, repo) async {
  ref.watch(repoStatusProvider(repo));
  final r = await GitCli(repo).run([
    'for-each-ref',
    'refs/heads',
    branchesForEachRefFormat,
  ]);
  return parseForEachRefBranches(r.stdout);
});

/// `--format=` string used by [branchesProvider] (see [parseForEachRefBranches]).
const branchesForEachRefFormat = '--format=%(HEAD)%00%(refname:short)%00'
    '%(objectname:short)%00%(upstream:short)%00%(upstream:track,nobracket)%00'
    '%(contents:subject)';

/// Parses `git for-each-ref refs/heads $branchesForEachRefFormat` output
/// (one ref per line, NUL-separated fields) into [BranchItem]s. A standalone
/// function (rather than inlined in the provider) so it's directly
/// unit-testable against real git output without needing a Riverpod
/// container.
List<BranchItem> parseForEachRefBranches(String stdout) {
  final items = <BranchItem>[];
  for (final line in stdout.split('\n')) {
    if (!line.contains('\x00')) continue; // blank trailing line
    final f = line.split('\x00');
    if (f.length < 6) continue; // malformed — skip defensively
    final track = _parseTrack(f[4]);
    items.add(BranchItem(
      name: f[1],
      shortOid: f[2],
      isHead: f[0] == '*',
      upstream: f[3].isEmpty ? null : f[3],
      ahead: track.ahead,
      behind: track.behind,
      gone: track.gone,
      subject: f[5],
    ));
  }
  return items;
}

/// One remote-tracking branch (`refs/remotes/<remote>/<name>`).
class RemoteBranchItem {
  final String remote;
  final String name;
  final String shortOid;

  const RemoteBranchItem({
    required this.remote,
    required this.name,
    required this.shortOid,
  });

  /// Remote-qualified short name, e.g. `origin/feature` — what
  /// `checkoutRemoteBranch` and git plumbing expect.
  String get fullName => '$remote/$name';
}

/// Remote-tracking branch listing, grouped by remote in the left panel.
///
/// Uses the *full* refname (not `refname:short`) to find and skip each
/// remote's `HEAD` symref: for `refs/remotes/origin/HEAD`,
/// `%(refname:short)` collapses to plain `origin` (no `/HEAD` suffix at
/// all — verified against real git), so the full form is the only reliable
/// way to recognise and drop it.
final remoteBranchesProvider = FutureProvider.autoDispose
    .family<List<RemoteBranchItem>, String>((ref, repo) async {
  ref.watch(repoStatusProvider(repo));
  final r = await GitCli(repo).run([
    'for-each-ref',
    'refs/remotes',
    remoteBranchesForEachRefFormat,
  ]);
  return parseForEachRefRemoteBranches(r.stdout);
});

/// `--format=` string used by [remoteBranchesProvider].
const remoteBranchesForEachRefFormat = '--format=%(refname)%00%(objectname:short)';

/// Parses `git for-each-ref refs/remotes $remoteBranchesForEachRefFormat`
/// output into [RemoteBranchItem]s, dropping each remote's `HEAD` symref.
/// Standalone for the same testability reason as [parseForEachRefBranches].
List<RemoteBranchItem> parseForEachRefRemoteBranches(String stdout) {
  const prefix = 'refs/remotes/';
  final items = <RemoteBranchItem>[];
  for (final line in stdout.split('\n')) {
    if (!line.contains('\x00')) continue;
    final f = line.split('\x00');
    if (f.length < 2) continue;
    final fullRef = f[0];
    if (!fullRef.startsWith(prefix) || fullRef.endsWith('/HEAD')) continue;
    final rest = fullRef.substring(prefix.length);
    final slash = rest.indexOf('/');
    if (slash < 0) continue; // malformed — skip defensively
    items.add(RemoteBranchItem(
      remote: rest.substring(0, slash),
      name: rest.substring(slash + 1),
      shortOid: f[1],
    ));
  }
  return items;
}

/// Configured remote names (`git remote`).
final remotesProvider =
    FutureProvider.autoDispose.family<List<String>, String>((ref, repo) async {
  ref.watch(repoStatusProvider(repo));
  final r = await GitCli(repo).run(['remote']);
  return r.stdout.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
});

/// Stash listing for the left panel.
final stashesProvider = FutureProvider.autoDispose
    .family<List<StashItem>, String>((ref, repo) async {
  ref.watch(repoStatusProvider(repo));
  final r =
      await GitCli(repo).run(['stash', 'list', '-z', '--format=%gd%x1f%gs']);
  return parseStashListZ(r.stdout);
});

/// The multi-step operation (merge/rebase/cherry-pick/revert) currently in
/// progress, if any — drives the status panel's conflict-resolution banner.
final repoOpStateProvider = FutureProvider.autoDispose
    .family<RepoOpState, String>((ref, repo) async {
  ref.watch(repoStatusProvider(repo));
  return detectOpState(repo);
});

/// Branch and merge-conflict operations invoked from the left panel and the
/// status panel's conflict banner. Every operation refreshes
/// [repoStatusProvider] on success (or, for [mergeBranch], regardless of
/// outcome — a failed merge still leaves conflict markers the status
/// snapshot needs to pick up); git failures propagate to the caller so the
/// UI can surface them (e.g. in a SnackBar).
class BranchOps {
  final String repo;
  final WidgetRef ref;

  BranchOps(this.repo, this.ref);

  GitCli get _git => GitCli(repo);

  Future<void> _refresh() =>
      ref.read(repoStatusProvider(repo).notifier).refresh();

  Future<void> createBranch(String name, {bool checkout = true}) async {
    await _git.run(checkout ? ['checkout', '-b', name] : ['branch', name]);
    await _refresh();
  }

  Future<void> checkoutBranch(String name) async {
    await _git.run(['checkout', name]);
    await _refresh();
  }

  /// Checks out [remoteBranch] (e.g. `origin/feature`) as a new local
  /// tracking branch named after the part following the first `/`. If a
  /// local branch with that name already exists, `git checkout -b` fails —
  /// the [GitException] is left to propagate so the UI can SnackBar it
  /// rather than silently overwriting or guessing a different name.
  Future<void> checkoutRemoteBranch(String remoteBranch) async {
    final slash = remoteBranch.indexOf('/');
    final local =
        slash < 0 ? remoteBranch : remoteBranch.substring(slash + 1);
    await _git.run(['checkout', '-b', local, '--track', remoteBranch]);
    await _refresh();
  }

  Future<void> renameBranch(String oldName, String newName) async {
    await _git.run(['branch', '-m', oldName, newName]);
    await _refresh();
  }

  /// The caller decides whether to force: try `force: false` first and, on
  /// a [GitException] whose message contains 'not fully merged', re-invoke
  /// with `force: true` after user confirmation.
  Future<void> deleteBranch(String name, {bool force = false}) async {
    await _git.run(['branch', force ? '-D' : '-d', name]);
    await _refresh();
  }

  /// Merges [name] into the current branch. Returns the [GitResult] instead
  /// of throwing on a non-zero exit so the caller can distinguish a real
  /// conflict (files to resolve) from any other failure — the status
  /// snapshot is refreshed either way since a failed merge still changes the
  /// working tree (conflict markers, MERGE_HEAD).
  Future<GitResult> mergeBranch(String name) async {
    final result = await _git.run(['merge', '--no-edit', name], check: false);
    await _refresh();
    return result;
  }

  /// Concludes an in-progress merge once conflicts are resolved: commits
  /// using the prepared `MERGE_MSG`.
  Future<void> continueMerge() async {
    await _git.run(['commit', '--no-edit']);
    await _refresh();
  }

  Future<void> abortMerge() async {
    await _git.run(['merge', '--abort']);
    await _refresh();
  }

  Future<void> resolveOurs(String path) async {
    await _git.run(['checkout', '--ours', '--', path]);
    await _git.run(['add', '--', path]);
    await _refresh();
  }

  Future<void> resolveTheirs(String path) async {
    await _git.run(['checkout', '--theirs', '--', path]);
    await _git.run(['add', '--', path]);
    await _refresh();
  }

  Future<void> markResolved(String path) async {
    await _git.run(['add', '--', path]);
    await _refresh();
  }
}

/// Stash operations invoked from the left panel.
class StashOps {
  final String repo;
  final WidgetRef ref;

  StashOps(this.repo, this.ref);

  GitCli get _git => GitCli(repo);

  Future<void> _refresh() =>
      ref.read(repoStatusProvider(repo).notifier).refresh();

  Future<void> push({String? message, bool includeUntracked = true}) async {
    await _git.run([
      'stash',
      'push',
      if (includeUntracked) '-u',
      if (message != null && message.trim().isNotEmpty)
        ...['-m', message.trim()],
    ]);
    await _refresh();
  }

  Future<void> apply(String rawRef) async {
    await _git.run(['stash', 'apply', rawRef]);
    await _refresh();
  }

  Future<void> pop(String rawRef) async {
    await _git.run(['stash', 'pop', rawRef]);
    await _refresh();
  }

  Future<void> drop(String rawRef) async {
    await _git.run(['stash', 'drop', rawRef]);
    await _refresh();
  }

  /// Read-only — no status refresh needed. Some older git versions can exit
  /// non-zero for `-u` against a stash that has no untracked files of its
  /// own; on that failure, retry without `-u` before giving up.
  Future<List<FileDiff>> show(String rawRef) async {
    final withUntracked =
        await _git.run(['stash', 'show', '-p', '-u', '--no-color', rawRef],
            check: false);
    if (withUntracked.exitCode == 0) {
      return parseUnifiedDiff(withUntracked.stdout);
    }
    final r =
        await _git.run(['stash', 'show', '-p', '--no-color', rawRef]);
    return parseUnifiedDiff(r.stdout);
  }
}
