@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/git_dirs.dart';
import 'package:branch_pilot/git/parsers/porcelain_status.dart';
import 'package:branch_pilot/git/parsers/worktree_list.dart';
import 'package:branch_pilot/repo/power_providers.dart'
    show
        parseForEachRefTags,
        tagsForEachRefFormat,
        parseFileHistoryZ,
        fileHistoryLogFormat;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The P7 acceptance tests for tag / cherry-pick / revert / reset / worktree
/// operations. As with branch_ops_test.dart, this exercises the exact git
/// command sequences `PowerOps` runs directly against real git fixtures —
/// `PowerOps` needs a `WidgetRef`, which only a pumped widget tree can supply
/// (integration_test/power_ops_test.dart covers the two trickiest UI paths:
/// the hard-reset typed-confirmation gate and the cherry-pick conflict
/// banner).
void main() {
  /// The temp root created for one test: contains the fixture repo at
  /// `root/repo` plus, for the worktree tests, any linked worktrees as
  /// siblings of it — everything lives under this one directory so
  /// `tearDown` cleans up the repo *and* its worktrees in one recursive
  /// delete, with nothing ever placed outside [Directory.systemTemp].
  late Directory root;
  late Directory tmp;

  GitCli git() => GitCli(tmp.path);

  Future<GitResult> g(List<String> args,
          {bool check = true, Map<String, String>? environment}) =>
      git().run(args, check: check, environment: environment);

  Future<void> write(String rel, String content) =>
      File(p.join(tmp.path, rel)).writeAsString(content, flush: true);

  Future<String> head() async =>
      (await git().run(['rev-parse', 'HEAD'])).stdout.trim();

  Future<StatusSnapshot> snapshot() async {
    final r = await git().run(['status', '--porcelain=v2', '--branch', '-z']);
    return parsePorcelainV2(r.stdout);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('branchpilot_powerops_');
    tmp = Directory(p.join(root.path, 'repo'));
    await tmp.create(recursive: true);
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'p@test.local']);
    await g(['config', 'user.name', 'PowerOps']);
    await g(['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  group('tags', () {
    test(
        'lightweight on HEAD~1 + annotated with message on HEAD via the '
        'exact op commands; for-each-ref shows both correctly; delete removes',
        () async {
      await write('f.txt', 'one\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'first']);
      final first = await head();

      await write('f.txt', 'two\n');
      await g(['commit', '-am', 'second']);

      // createTag('light', onCommit: first, message: null) ->
      // ['tag', 'light', first]
      await g(['tag', 'light', first]);
      // createTag('annotated', onCommit: null, message: 'Tag message') ->
      // ['tag', '-a', 'annotated', '-m', 'Tag message']  (applies to HEAD)
      await g(['tag', '-a', 'annotated', '-m', 'Tag message']);

      final r = await git()
          .run(['for-each-ref', 'refs/tags', tagsForEachRefFormat]);
      final tags = parseForEachRefTags(r.stdout);
      expect(tags, hasLength(2));

      final light = tags.firstWhere((t) => t.name == 'light');
      expect(light.annotated, isFalse,
          reason: 'a lightweight tag points straight at the commit object');
      expect(light.message, isNull);

      final annotated = tags.firstWhere((t) => t.name == 'annotated');
      expect(annotated.annotated, isTrue);
      expect(annotated.message, 'Tag message');

      // deleteTag('light') -> ['tag', '-d', 'light']
      await g(['tag', '-d', 'light']);
      final after = parseForEachRefTags((await git()
              .run(['for-each-ref', 'refs/tags', tagsForEachRefFormat]))
          .stdout);
      expect(after, hasLength(1));
      expect(after.single.name, 'annotated');
    });
  });

  group('cherry-pick', () {
    test('a clean cherry-pick applies the commit on top of main', () async {
      await write('base.txt', 'base\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'base']);

      await g(['checkout', '-b', 'side']);
      await write('side.txt', 'side content\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'side commit']);
      final sideHash = await head();

      await g(['checkout', 'main']);
      // cherryPick(hash) -> ['cherry-pick', hash] check:false
      final result = await g(['cherry-pick', sideHash], check: false);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(File(p.join(tmp.path, 'side.txt')).existsSync(), isTrue);
      final log = await git().run(['log', '-1', '--format=%s']);
      expect(log.stdout.trim(), 'side commit');
    });

    test(
        'a conflicting cherry-pick pauses with the cherryPicking op state; '
        'resolving and continuing (GIT_EDITOR=true) completes it', () async {
      await write('shared.txt', 'base\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'base']);

      await g(['checkout', '-b', 'side']);
      await write('shared.txt', 'side change\n');
      await g(['commit', '-am', 'side commit']);
      final sideHash = await head();

      await g(['checkout', 'main']);
      await write('shared.txt', 'main change\n');
      await g(['commit', '-am', 'main commit']);

      final result = await g(['cherry-pick', sideHash], check: false);
      expect(result.exitCode, isNot(0));
      expect(await detectOpState(tmp.path), RepoOpState.cherryPicking);
      expect((await snapshot()).hasConflicts, isTrue);

      await write('shared.txt', 'resolved\n');
      await g(['add', 'shared.txt']);

      // continueSequencer(cherryPicking) -> ['cherry-pick', '--continue']
      // with environment {'GIT_EDITOR': 'true'}
      final cont = await g(['cherry-pick', '--continue'],
          check: false, environment: const {'GIT_EDITOR': 'true'});
      expect(cont.exitCode, 0, reason: cont.stderr);
      expect(await detectOpState(tmp.path), RepoOpState.none);
      expect(await File(p.join(tmp.path, 'shared.txt')).readAsString(),
          'resolved\n');
    });

    test(
        'a second conflicting cherry-pick can be aborted back to the '
        'original HEAD', () async {
      await write('shared.txt', 'base\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'base']);

      await g(['checkout', '-b', 'side']);
      await write('shared.txt', 'side change\n');
      await g(['commit', '-am', 'side commit']);
      final sideHash = await head();

      await g(['checkout', 'main']);
      await write('shared.txt', 'main change\n');
      await g(['commit', '-am', 'main commit']);
      final beforePick = await head();

      final result = await g(['cherry-pick', sideHash], check: false);
      expect(result.exitCode, isNot(0));
      expect(await detectOpState(tmp.path), RepoOpState.cherryPicking);

      // abortSequencer(cherryPicking) -> ['cherry-pick', '--abort']
      await g(['cherry-pick', '--abort']);
      expect(await head(), beforePick);
      expect(await detectOpState(tmp.path), RepoOpState.none);
    });
  });

  group('revert', () {
    test(
        'revert HEAD restores the file content and the subject starts with '
        '"Revert"', () async {
      await write('r.txt', 'original\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'add r.txt']);
      await write('r.txt', 'changed\n');
      await g(['commit', '-am', 'change r.txt']);

      // revert(hash) -> ['revert', '--no-edit', hash] check:false
      final result = await g(['revert', '--no-edit', 'HEAD'], check: false);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(
          await File(p.join(tmp.path, 'r.txt')).readAsString(), 'original\n');
      final log = await git().run(['log', '-1', '--format=%s']);
      expect(log.stdout.trim(), startsWith('Revert'));
    });
  });

  group('reset', () {
    test(
        '--soft leaves the index (and worktree) as-is, so it now differs '
        'from the rewound HEAD; a subsequent --mixed no-op move clears the '
        'index back to matching HEAD', () async {
      await write('f.txt', 'first\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'first']);
      final first = await head();

      await write('f.txt', 'second\n');
      await g(['commit', '-am', 'second']);

      // A worktree edit staged on top of HEAD (commit 2).
      await write('f.txt', 'staged-edit\n');
      await g(['add', 'f.txt']);

      // reset(first, mode: 'soft') -> ['reset', '--soft', first]
      await g(['reset', '--soft', first]);
      expect(await head(), first);
      final cachedAfterSoft =
          await git().run(['diff', '--cached', '--', 'f.txt']);
      expect(cachedAfterSoft.stdout, isNotEmpty,
          reason: 'soft leaves the index untouched, so diffing it against '
              'the rewound HEAD now shows the commit\'s changes as staged');
      expect(await File(p.join(tmp.path, 'f.txt')).readAsString(),
          'staged-edit\n',
          reason: 'soft never touches the working tree');

      // reset(head, mode: 'mixed') -> ['reset', '--mixed', head] — HEAD is
      // already `first`, so this is a no-op move; --mixed still resets the
      // index to match it.
      await g(['reset', '--mixed', first]);
      expect(await head(), first);
      final cachedAfterMixed =
          await git().run(['diff', '--cached', '--', 'f.txt']);
      expect(cachedAfterMixed.stdout, isEmpty,
          reason: 'mixed resets the index to match HEAD, clearing what was '
              'staged after the soft reset');
      final worktreeDiff = await git().run(['diff', '--', 'f.txt']);
      expect(worktreeDiff.stdout, isNotEmpty,
          reason: 'the same content now shows up as unstaged instead');
      expect(await File(p.join(tmp.path, 'f.txt')).readAsString(),
          'staged-edit\n',
          reason: 'mixed does not touch the working tree either');
    });

    test(
        '--hard on a fresh setup moves HEAD and rewrites the worktree, '
        'leaving status clean', () async {
      await write('f.txt', 'first\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'first']);
      final first = await head();

      await write('f.txt', 'second\n');
      await g(['commit', '-am', 'second']);

      // reset(first, mode: 'hard') -> ['reset', '--hard', first]
      await g(['reset', '--hard', first]);
      expect(await head(), first);
      expect(
          await File(p.join(tmp.path, 'f.txt')).readAsString(), 'first\n');
      final status = await git().run(['status', '--porcelain']);
      expect(status.stdout.trim(), isEmpty);
    });
  });

  group('worktrees', () {
    test(
        'add lists 2 entries with the linked worktree on its new branch; '
        'remove drops back to 1', () async {
      await write('f.txt', 'base\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'base']);

      // A sibling of the repo, inside this test's own temp root — never a
      // literal `../…` argument, and never outside Directory.systemTemp.
      final wt1 = p.join(root.path, 'wt1');

      // addWorktree(wt1, newBranch: 'feature-wt') ->
      // ['worktree', 'add', '-b', 'feature-wt', wt1]
      await g(['worktree', 'add', '-b', 'feature-wt', wt1]);

      final listed =
          await git().run(['worktree', 'list', '--porcelain', '-z']);
      final entries = parseWorktreeListZ(listed.stdout);
      expect(entries, hasLength(2));
      final linked = entries.firstWhere((w) => w.path == wt1);
      expect(linked.branch, 'feature-wt');

      // removeWorktree(wt1) -> ['worktree', 'remove', wt1]
      await g(['worktree', 'remove', wt1]);
      final afterRemove = parseWorktreeListZ(
          (await git().run(['worktree', 'list', '--porcelain', '-z']))
              .stdout);
      expect(afterRemove, hasLength(1));
    });

    test(
        'removing a worktree with untracked files throws without force; '
        'force:true removes it', () async {
      await write('f.txt', 'base\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'base']);

      final wt2 = p.join(root.path, 'wt2');
      await g(['worktree', 'add', '-b', 'dirty-wt', wt2]);
      await File(p.join(wt2, 'untracked.txt'))
          .writeAsString('dirt\n', flush: true);

      // removeWorktree(wt2, force: false) -> ['worktree', 'remove', wt2]
      GitException? caught;
      try {
        await g(['worktree', 'remove', wt2]);
      } on GitException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull,
          reason: 'a dirty worktree must not be removed without --force');
      expect(Directory(wt2).existsSync(), isTrue);

      // removeWorktree(wt2, force: true) ->
      // ['worktree', 'remove', '--force', wt2]
      await g(['worktree', 'remove', '--force', wt2]);
      expect(Directory(wt2).existsSync(), isFalse);
    });
  });

  group('file history', () {
    test(
        '--follow crosses a rename: committed, modified, renamed (git mv), '
        'modified again → all 4 commits show up for the new name', () async {
      await write('f.txt', 'v1\n');
      await g(['add', '.']);
      await g(['commit', '-m', 'commit 1']);

      await write('f.txt', 'v2\n');
      await g(['commit', '-am', 'commit 2']);

      await g(['mv', 'f.txt', 'g.txt']);
      await g(['commit', '-m', 'commit 3 rename']);

      await write('g.txt', 'v3\n');
      await g(['commit', '-am', 'commit 4']);

      // The exact command fileHistoryProvider runs.
      final r = await git().run([
        'log',
        '--follow',
        '-z',
        '--pretty=format:$fileHistoryLogFormat',
        '--',
        'g.txt',
      ]);
      final entries = parseFileHistoryZ(r.stdout);
      expect(entries, hasLength(4),
          reason: '--follow must cross the rename to see commits 1 and 2');
      expect(entries.map((e) => e.subject),
          ['commit 4', 'commit 3 rename', 'commit 2', 'commit 1']);
    });
  });
}
