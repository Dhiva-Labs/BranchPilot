@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/git_dirs.dart';
import 'package:branch_pilot/git/parsers/porcelain_status.dart';
import 'package:branch_pilot/git/parsers/stash_list.dart';
import 'package:branch_pilot/repo/branch_providers.dart'
    show branchesForEachRefFormat, parseForEachRefBranches;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The P4 acceptance tests for branch/merge/stash operations. As with
/// commit_flow_test.dart, this exercises the exact git command sequences
/// `BranchOps`/`StashOps` use directly against a real git fixture — those
/// classes need a `WidgetRef`, which only a pumped widget tree can supply
/// (integration_test/merge_flow_test.dart and branch_stash_test.dart cover
/// the UI). `parseForEachRefBranches` has no such dependency, so it's
/// exercised directly here against real `for-each-ref` output.
void main() {
  late Directory tmp;

  GitCli git() => GitCli(tmp.path);

  Future<void> g(List<String> args) async => git().run(args);

  Future<void> write(String rel, String content) =>
      File(p.join(tmp.path, rel)).writeAsString(content, flush: true);

  Future<StatusSnapshot> snapshot() async {
    final r = await git().run(['status', '--porcelain=v2', '--branch', '-z']);
    return parsePorcelainV2(r.stdout);
  }

  Future<String> currentBranch() async =>
      (await git().run(['branch', '--show-current'])).stdout.trim();

  /// Exactly what `StashOps` uses to list stashes.
  Future<List<StashItem>> stashList() async {
    final r =
        await git().run(['stash', 'list', '-z', '--format=%gd%x1f%gs']);
    return parseStashListZ(r.stdout);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_branchops_');
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'b@test.local']);
    await g(['config', 'user.name', 'BranchOps']);
    await g(['config', 'commit.gpgsign', 'false']);
    await write('f.txt', 'base\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base commit']);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('branchesProvider parsing', () {
    test(
        'for-each-ref branch listing: HEAD, upstream ahead/behind, and a '
        'branch with no upstream', () async {
      final remote =
          await Directory.systemTemp.createTemp('branchpilot_branchops_remote_');
      addTearDown(() => remote.delete(recursive: true));
      await GitCli(remote.path).run(['init', '--bare', '-b', 'main']);
      await g(['remote', 'add', 'origin', remote.path]);
      await g(['push', '-u', 'origin', 'main']);
      await write('f.txt', 'ahead change\n');
      await g(['commit', '-am', 'ahead commit']);

      await g(['checkout', '-b', 'feature']);
      await write('feature.txt', 'feature content\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'feature commit']);
      await g(['checkout', 'main']);

      // The EXACT command branchesProvider runs.
      final r = await git()
          .run(['for-each-ref', 'refs/heads', branchesForEachRefFormat]);
      final items = parseForEachRefBranches(r.stdout);
      expect(items, hasLength(2));

      final main = items.firstWhere((b) => b.name == 'main');
      expect(main.isHead, isTrue);
      expect(main.upstream, 'origin/main');
      expect(main.ahead, 1);
      expect(main.behind, 0);
      expect(main.gone, isFalse);
      expect(main.subject, 'ahead commit');

      final feature = items.firstWhere((b) => b.name == 'feature');
      expect(feature.isHead, isFalse);
      expect(feature.upstream, isNull);
      expect(feature.ahead, 0);
      expect(feature.behind, 0);
      expect(feature.gone, isFalse);
      expect(feature.subject, 'feature commit');
    });
  });

  group('create/rename/delete', () {
    test('create → rename → delete cycle via the exact BranchOps commands',
        () async {
      // createBranch(name, checkout: true) -> ['checkout', '-b', name]
      await g(['checkout', '-b', 'temp-branch']);
      expect(await currentBranch(), 'temp-branch');

      // renameBranch(old, new) -> ['branch', '-m', old, new]
      await g(['branch', '-m', 'temp-branch', 'renamed-branch']);
      expect(await currentBranch(), 'renamed-branch');

      await g(['checkout', 'main']);

      // deleteBranch(name, force: false) -> ['branch', '-d', name]
      await g(['branch', '-d', 'renamed-branch']);
      final list = await git().run(['branch', '--list']);
      expect(list.stdout.contains('renamed-branch'), isFalse);
    });

    test("deleting an unmerged branch: -d throws 'not fully merged', -D succeeds",
        () async {
      await g(['checkout', '-b', 'unmerged-branch']);
      await write('unmerged.txt', 'content\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'unmerged commit']);
      await g(['checkout', 'main']);

      GitException? caught;
      try {
        await g(['branch', '-d', 'unmerged-branch']);
      } on GitException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught.toString(), contains('not fully merged'));

      // Branch must still exist — the soft delete failed.
      final stillThere = await git().run(['branch', '--list']);
      expect(stillThere.stdout.contains('unmerged-branch'), isTrue);

      // deleteBranch(name, force: true) -> ['branch', '-D', name]
      await g(['branch', '-D', 'unmerged-branch']);
      final afterForce = await git().run(['branch', '--list']);
      expect(afterForce.stdout.contains('unmerged-branch'), isFalse);
    });
  });

  group('merge conflict lifecycle', () {
    test(
        'merge --no-edit conflicts, resolveOurs clears it, continueMerge '
        'commits the merge, and op state returns to none', () async {
      await write('conf.txt', 'base\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'base conf']);

      await g(['checkout', '-b', 'conflict-branch']);
      await write('conf.txt', 'from conflict-branch\n');
      await g(['commit', '-am', 'edit on conflict-branch']);

      await g(['checkout', 'main']);
      await write('conf.txt', 'from main\n');
      await g(['commit', '-am', 'edit on main']);

      // mergeBranch(name) -> ['merge', '--no-edit', name] with check:false
      final mergeResult =
          await git().run(['merge', '--no-edit', 'conflict-branch'], check: false);
      expect(mergeResult.exitCode, isNot(0));

      var s = await snapshot();
      expect(s.hasConflicts, isTrue);
      expect(s.conflicted.single.path, 'conf.txt');
      expect(await detectOpState(tmp.path), RepoOpState.merging);

      // resolveOurs(path) -> ['checkout','--ours','--',path] then
      // ['add','--',path]
      await g(['checkout', '--ours', '--', 'conf.txt']);
      await g(['add', '--', 'conf.txt']);

      s = await snapshot();
      expect(s.conflicted, isEmpty);
      // Still mid-merge (MERGE_HEAD present) until the merge is committed.
      expect(await detectOpState(tmp.path), RepoOpState.merging);

      // continueMerge() -> ['commit', '--no-edit']
      await g(['commit', '--no-edit']);

      final merges = await git().run(['log', '--merges', '--oneline']);
      final mergeLines =
          merges.stdout.split('\n').where((l) => l.trim().isNotEmpty);
      expect(mergeLines, hasLength(1));

      expect(await detectOpState(tmp.path), RepoOpState.none);

      final resolved = await File(p.join(tmp.path, 'conf.txt')).readAsString();
      expect(resolved, 'from main\n');
    });

    test('resolveTheirs takes the incoming side', () async {
      await write('conf2.txt', 'base\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'base conf2']);

      await g(['checkout', '-b', 'their-branch']);
      await write('conf2.txt', 'their content\n');
      await g(['commit', '-am', 'their edit']);

      await g(['checkout', 'main']);
      await write('conf2.txt', 'our content\n');
      await g(['commit', '-am', 'our edit']);

      await git().run(['merge', '--no-edit', 'their-branch'], check: false);
      expect((await snapshot()).hasConflicts, isTrue);

      // resolveTheirs(path) -> ['checkout','--theirs','--',path] then
      // ['add','--',path]
      await g(['checkout', '--theirs', '--', 'conf2.txt']);
      await g(['add', '--', 'conf2.txt']);

      expect((await snapshot()).conflicted, isEmpty);
      final content = await File(p.join(tmp.path, 'conf2.txt')).readAsString();
      expect(content, 'their content\n');

      await g(['commit', '--no-edit']);
      expect(await detectOpState(tmp.path), RepoOpState.none);
    });
  });

  group('stash', () {
    test('push (dirty + untracked) → list → apply keeps the entry → drop',
        () async {
      await write('f.txt', 'dirty change\n');
      await write('new_untracked.txt', 'untracked content\n');

      // push({message, includeUntracked: true}) ->
      // ['stash', 'push', '-u', '-m', message]
      await g(['stash', 'push', '-u', '-m', 'test stash message']);

      expect((await snapshot()).isClean, isTrue);

      var stashes = await stashList();
      expect(stashes, hasLength(1));
      expect(stashes.single.rawRef, 'stash@{0}');
      expect(stashes.single.message, contains('test stash message'));

      // apply(rawRef) -> ['stash', 'apply', rawRef]
      await g(['stash', 'apply', 'stash@{0}']);
      final s = await snapshot();
      expect(s.unstaged.map((e) => e.path), contains('f.txt'));
      expect(s.untracked.map((e) => e.path), contains('new_untracked.txt'));

      stashes = await stashList();
      expect(stashes, hasLength(1),
          reason: 'apply keeps the stash entry; only drop/pop removes it');

      // drop(rawRef) -> ['stash', 'drop', rawRef]
      await g(['stash', 'drop', 'stash@{0}']);
      expect(await stashList(), isEmpty);
    });

    test('pop restores changes and removes the entry in one step', () async {
      await write('f.txt', 'dirty change again\n');
      await g(['stash', 'push', '-u', '-m', 'pop test']);
      expect(await stashList(), hasLength(1));
      expect((await snapshot()).isClean, isTrue);

      // pop(rawRef) -> ['stash', 'pop', rawRef]
      await g(['stash', 'pop', 'stash@{0}']);
      expect(await stashList(), isEmpty);
      expect((await snapshot()).unstaged.map((e) => e.path), contains('f.txt'));
    });
  });
}
