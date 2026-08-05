@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/repo/branch_providers.dart';
import 'package:branch_pilot/repo/graph_providers.dart';
import 'package:branch_pilot/repo/power_providers.dart';
import 'package:branch_pilot/repo/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The P8 "refresh everything" investigation, made concrete as a test.
///
/// repo_screen.dart's header refresh button only ever calls
/// `repoStatusProvider(repo).notifier.refresh()`. The investigation (see its
/// doc comment on `_refreshEverything`) found that every provider listing
/// repo-wide data — branches, tags, stashes, worktrees, remote-tracking
/// branches, and the commit graph — already either `ref.watch`es or
/// `ref.listen`s `repoStatusProvider`, and `RepoStatusNotifier.refresh()`
/// always assigns a brand-new `StatusSnapshot` (parsed fresh every call, and
/// nothing in that class tree overrides `==`), so Riverpod never treats a
/// refresh as a no-op — every one of those already cascades from that single
/// call. This file proves that against real git fixtures rather than
/// trusting the reasoning: each test makes a change entirely *outside* the
/// app (plain `GitCli` calls, exactly like a user's terminal next to the
/// window) and confirms one `refresh()` call is enough for every provider to
/// pick it up. No provider needed an explicit `ref.invalidate` — if a future
/// change (e.g. a memoized `==` on `StatusSnapshot`) ever broke that
/// cascade, it would fail here.
void main() {
  late Directory tmp;
  late ProviderContainer container;

  GitCli git() => GitCli(tmp.path);
  Future<GitResult> g(List<String> args) => git().run(args);
  Future<void> write(String rel, String content) =>
      File(p.join(tmp.path, rel)).writeAsString(content, flush: true);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_refresh_');
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'refresh@test.local']);
    await g(['config', 'user.name', 'Refresh']);
    await g(['config', 'commit.gpgsign', 'false']);
    await write('f.txt', 'one\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'init']);

    container = ProviderContainer();
    // Persistent listeners, mirroring how the real app keeps every one of
    // these alive for as long as a repo tab is open (RepoWorkspace watches
    // repoStatusProvider directly; LeftPanel/CommitGraphView watch the
    // rest). An autoDispose provider with no active listener would just get
    // torn down and rebuilt from scratch on the next read, which would hide
    // exactly the cascade behaviour this file is trying to prove.
    container.listen(repoStatusProvider(tmp.path), (_, _) {});
    container.listen(branchesProvider(tmp.path), (_, _) {});
    container.listen(tagsProvider(tmp.path), (_, _) {});
    container.listen(stashesProvider(tmp.path), (_, _) {});
    container.listen(worktreesProvider(tmp.path), (_, _) {});
    container.listen(commitGraphProvider(tmp.path), (_, _) {});

    // Let the initial load settle before any test starts mutating things.
    await container.read(repoStatusProvider(tmp.path).future);
    await container.read(branchesProvider(tmp.path).future);
    await container.read(tagsProvider(tmp.path).future);
    await container.read(stashesProvider(tmp.path).future);
    await container.read(worktreesProvider(tmp.path).future);
    await container.read(commitGraphProvider(tmp.path).future);
  });

  tearDown(() async {
    container.dispose();
    await tmp.delete(recursive: true);
  });

  Future<void> refresh() =>
      container.read(repoStatusProvider(tmp.path).notifier).refresh();

  /// Polls [read] until [predicate] holds. Needed for [commitGraphProvider]
  /// specifically: unlike the plain `FutureProvider.family`s above (whose
  /// `.future` is replaced synchronously the moment their `ref.watch`ed
  /// `repoStatusProvider` changes), `CommitGraphNotifier` reacts via
  /// `ref.listen` and only reassigns its own `state` once its *own* async
  /// reload finishes — so its `.future` right after `refresh()` can still be
  /// the old (already-resolved) value's future for a few milliseconds.
  Future<T> waitUntil<T>(T Function() read, bool Function(T) predicate,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final v = read();
      if (predicate(v)) return v;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('condition not met within $timeout');
  }

  test(
      'one refresh() picks up a tag, a stash, a worktree, a new branch, and '
      'a new commit — all made entirely outside the app', () async {
    expect(container.read(tagsProvider(tmp.path)).valueOrNull, isEmpty);
    expect(container.read(stashesProvider(tmp.path)).valueOrNull, isEmpty);
    expect(container.read(worktreesProvider(tmp.path)).valueOrNull,
        hasLength(1));
    expect(
        container.read(branchesProvider(tmp.path)).valueOrNull, hasLength(1));
    final initialGraphCount =
        container.read(commitGraphProvider(tmp.path)).valueOrNull?.totalCount;
    expect(initialGraphCount, 1);

    // Everything below is a plain GitCli call, exactly as if the user had a
    // terminal open next to the app — none of it goes through an Ops class
    // or touches a provider.
    await g(['tag', '-a', 'v1', '-m', 'first release']);
    await write('f.txt', 'two\n');
    await g(['stash', 'push', '-m', 'wip']);
    final worktreeDir = p.join(tmp.parent.path, 'wt-${p.basename(tmp.path)}');
    addTearDown(() => Directory(worktreeDir).delete(recursive: true));
    await g(['worktree', 'add', '-b', 'side', worktreeDir]);
    await g(['checkout', '-b', 'topic']);
    await write('g.txt', 'new file\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'topic commit']);

    await refresh();

    final tags = await container.read(tagsProvider(tmp.path).future);
    expect(tags.map((t) => t.name), contains('v1'));

    final stashes = await container.read(stashesProvider(tmp.path).future);
    expect(stashes.map((s) => s.message), contains(contains('wip')));

    final worktrees =
        await container.read(worktreesProvider(tmp.path).future);
    expect(worktrees, hasLength(2));

    final branches = await container.read(branchesProvider(tmp.path).future);
    expect(branches.map((b) => b.name), contains('topic'));

    final graph = await waitUntil(
      () => container.read(commitGraphProvider(tmp.path)).valueOrNull,
      (g) => g != null && g.totalCount == initialGraphCount! + 1,
    );
    expect(graph!.totalCount, initialGraphCount! + 1);
  });

  test(
      'remoteBranchesProvider reflects a new remote-tracking ref discovered '
      'by a plain `git fetch` the app never initiated', () async {
    final bare =
        await Directory.systemTemp.createTemp('branchpilot_refresh_bare_');
    addTearDown(() => bare.delete(recursive: true));
    await GitCli(bare.path).run(['init', '--bare', '-b', 'main']);
    await g(['remote', 'add', 'origin', bare.path]);
    await g(['push', '-u', 'origin', 'main']);

    container.listen(remoteBranchesProvider(tmp.path), (_, _) {});
    final before =
        await container.read(remoteBranchesProvider(tmp.path).future);
    // `push -u` already updates the local origin/main tracking ref itself
    // (git's normal post-push behaviour), so it's already present — the new
    // branch below is not.
    expect(before.map((b) => b.fullName), isNot(contains('origin/teammate-feature')));

    // Simulate a teammate pushing a new branch to the shared remote: push
    // straight to a new ref on the bare repo, then fetch it — a plain
    // `git fetch`, run directly (not through NetworkOps/the app), same as a
    // user running it in a terminal next to the window.
    await g(['push', 'origin', 'main:refs/heads/teammate-feature']);
    await g(['fetch', 'origin']);

    await refresh();

    final after =
        await container.read(remoteBranchesProvider(tmp.path).future);
    expect(after.map((b) => b.fullName), contains('origin/teammate-feature'));
  });
}
