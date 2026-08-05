@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Real-git fixtures for the merge-commit `-m`/mainline behavior that
/// power_providers.dart's `PowerOps.cherryPick`/`revert` and
/// commit_graph_view.dart's mainline picker exist to handle: git refuses to
/// cherry-pick or revert a merge commit without `-m <mainline>`, and the
/// right mainline index changes which side of the merge gets undone/applied.
///
/// As with power_ops_test.dart, this exercises the exact git command
/// sequences directly (no `PowerOps`/`WidgetRef` needed for the git-level
/// behavior) — integration_test/merge_revert_test.dart covers the picker UI
/// and the full `PowerOps` call.
void main() {
  late Directory root;
  late Directory tmp;

  GitCli git() => GitCli(tmp.path);

  Future<GitResult> g(List<String> args, {bool check = true}) =>
      git().run(args, check: check);

  Future<void> write(String rel, String content) =>
      File(p.join(tmp.path, rel)).writeAsString(content, flush: true);

  Future<String> head() async =>
      (await git().run(['rev-parse', 'HEAD'])).stdout.trim();

  bool exists(String rel) => File(p.join(tmp.path, rel)).existsSync();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('branchpilot_mergecp_');
    tmp = Directory(p.join(root.path, 'repo'));
    await tmp.create(recursive: true);
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'm@test.local']);
    await g(['config', 'user.name', 'MergeCP']);
    await g(['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  /// Builds: main has base.txt (commit 'base'); branch 'side' adds side.txt
  /// (commit 'side commit'); back on main, main.txt is added (commit 'main
  /// commit'); then `git merge --no-ff side -m 'merge side'` makes HEAD a
  /// real 2-parent merge — parent 1 is the prior main tip (has base.txt +
  /// main.txt), parent 2 is the side tip (has base.txt + side.txt).
  Future<({String base, String main, String side, String merge})>
      makeMergeFixture() async {
    await write('base.txt', 'base\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
    final base = await head();

    await g(['checkout', '-b', 'side']);
    await write('side.txt', 'side content\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'side commit']);
    final side = await head();

    await g(['checkout', 'main']);
    await write('main.txt', 'main content\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'main commit']);
    final mainTip = await head();

    await g(['merge', '--no-ff', 'side', '-m', 'merge side']);
    final merge = await head();

    return (base: base, main: mainTip, side: side, merge: merge);
  }

  test(
      'documents the bug: reverting a merge with no -m fails, stderr '
      'mentions "is a merge"', () async {
    final fixture = await makeMergeFixture();

    // revert(hash) with no mainline -> ['revert', '--no-edit', hash]
    final result =
        await g(['revert', '--no-edit', fixture.merge], check: false);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('is a merge'),
        reason: 'this exact message is why the mainline picker exists');
  });

  test(
      'revert -m 1 undoes side\'s contribution relative to mainline parent '
      '1: side.txt is gone, main.txt (and base.txt) remain', () async {
    final fixture = await makeMergeFixture();

    // revert(hash, mainline: 1) -> ['revert', '--no-edit', '-m', '1', hash]
    final result = await g(
        ['revert', '--no-edit', '-m', '1', fixture.merge],
        check: false);
    expect(result.exitCode, 0, reason: result.stderr);
    expect(exists('side.txt'), isFalse,
        reason: 'parent 1 is the pre-merge main tip, which never had '
            'side.txt — reverting relative to it removes side\'s addition');
    expect(exists('main.txt'), isTrue);
    expect(exists('base.txt'), isTrue);
    final subject = await git().run(['log', '-1', '--format=%s']);
    expect(subject.stdout.trim(), startsWith('Revert'));
  });

  test(
      'revert -m 2 produces the opposite result: main.txt is gone, '
      'side.txt (and base.txt) remain', () async {
    final fixture = await makeMergeFixture();

    // revert(hash, mainline: 2) -> ['revert', '--no-edit', '-m', '2', hash]
    final result = await g(
        ['revert', '--no-edit', '-m', '2', fixture.merge],
        check: false);
    expect(result.exitCode, 0, reason: result.stderr);
    // Verified against real git output: -m 2 treats the *side* tip as the
    // mainline, so the revert undoes main's contribution relative to side —
    // main.txt disappears and side.txt is retained (the mirror image of the
    // -m 1 case above).
    expect(exists('main.txt'), isFalse);
    expect(exists('side.txt'), isTrue);
    expect(exists('base.txt'), isTrue);
  });

  test(
      'cherry-pick -m 1 onto a fresh branch from base applies side\'s '
      'changes (the non-mainline parent\'s contribution)', () async {
    final fixture = await makeMergeFixture();

    await g(['checkout', '-b', 'target', fixture.base]);
    expect(exists('side.txt'), isFalse,
        reason: 'sanity check: target starts from base, before either side');

    // cherryPick(hash, mainline: 1) ->
    // ['cherry-pick', '-m', '1', hash]
    final result =
        await g(['cherry-pick', '-m', '1', fixture.merge], check: false);
    expect(result.exitCode, 0, reason: result.stderr);
    // Verified against real git output: cherry-picking the merge with -m 1
    // replays the diff between parent 1 (main tip) and the merge commit,
    // which is exactly side's addition — side.txt shows up on `target`,
    // while main.txt (never part of that diff, and not on `target` to begin
    // with) still doesn't exist.
    expect(exists('side.txt'), isTrue);
    expect(exists('base.txt'), isTrue);
    expect(exists('main.txt'), isFalse);
  });

  test(
      '-m on a non-merge commit: -m 1 is silently accepted (parent 1 is '
      'just its one parent) but -m 2 fails referencing a nonexistent '
      'parent — real behavior differs from the naive "any -m errors" '
      'assumption, which is exactly why mainline must stay null unless '
      'CommitRecord.isMerge', () async {
    await write('f.txt', 'one\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'first']);
    await write('f.txt', 'two\n');
    await g(['commit', '-am', 'second']);
    final ordinary = await head();

    // On this system's git (verified via `strings` on the binary: it has no
    // "is not a merge"/"mainline was specified" string at all), `-m 1` on a
    // non-merge is NOT rejected — parent 1 already IS the commit's sole
    // parent, so git accepts it as equivalent to omitting -m.
    final mOne = await g(
        ['revert', '--no-edit', '-m', '1', ordinary],
        check: false);
    expect(mOne.exitCode, 0, reason: mOne.stderr);

    // The real failure mode is requesting a parent index that doesn't
    // exist: git's actual message is "does not have parent 2", not
    // anything mentioning "mainline".
    final mTwo = await g(
        ['revert', '--no-edit', '-m', '2', ordinary],
        check: false);
    expect(mTwo.exitCode, isNot(0));
    expect(mTwo.stderr, contains('does not have parent'));
  });
}
