@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/git_dirs.dart';
import 'package:branch_pilot/git/parsers/porcelain_status.dart';
import 'package:branch_pilot/git/rebase.dart';
import 'package:branch_pilot/repo/rebase_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The P6 acceptance: a scripted reorder + squash + reword + drop produces
/// the exact expected history, and a conflicted rebase pauses, resolves and
/// continues — including a reword whose editor invocation happens on the
/// `--continue` side of a conflict pause.
void main() {
  late Directory tmp;

  Future<void> g(List<String> args) async => GitCli(tmp.path).run(args);

  Future<void> write(String rel, String content) =>
      File(p.join(tmp.path, rel)).writeAsString(content, flush: true);

  Future<String> head() async =>
      (await GitCli(tmp.path).run(['rev-parse', 'HEAD'])).stdout.trim();

  Future<List<String>> messagesAbove(String base) async {
    final r = await GitCli(tmp.path).run(
        ['log', '--reverse', '-z', '--pretty=format:%B', '$base..HEAD']);
    return r.stdout
        .split('\x00')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<StatusSnapshot> snapshot() async {
    final r = await GitCli(tmp.path)
        .run(['status', '--porcelain=v2', '--branch', '-z']);
    return parsePorcelainV2(r.stdout);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_rebase_');
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'r@test.local']);
    await g(['config', 'user.name', 'Rebase']);
    await g(['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  /// base commit + one commit per [subjects], each adding its own file.
  Future<(String base, List<String> hashes)> history(
      List<String> subjects) async {
    await write('base.txt', 'base\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
    final base = await head();
    final hashes = <String>[];
    for (final (i, s) in subjects.indexed) {
      await write('f$i.txt', '$s\n');
      await g(['add', '.']);
      await g(['commit', '-m', s]);
      hashes.add(await head());
    }
    return (base, hashes);
  }

  test('reorder + squash + reword + drop → exact expected history', () async {
    final (base, h) = await history(['c1', 'c2', 'c3', 'c4']);
    // Final order: c3, squash c4 into it, reworded c1; c2 dropped.
    final plan = RebasePlan(baseHash: base, entries: [
      RebaseTodoEntry(hash: h[2], subject: 'c3'),
      RebaseTodoEntry(
          hash: h[3], subject: 'c4', action: RebaseAction.squash),
      RebaseTodoEntry(
          hash: h[0],
          subject: 'c1',
          action: RebaseAction.reword,
          newMessage: 'c1 reworded\n\nwith a body'),
      RebaseTodoEntry(hash: h[1], subject: 'c2', action: RebaseAction.drop),
    ]);

    final result = await RebaseDriver(tmp.path).startInteractive(plan);
    expect(result.exitCode, 0,
        reason: 'rebase should complete cleanly: ${result.stderr}');

    expect(await messagesAbove(base), [
      'c3\n\nc4', // squash: combined message, comments stripped
      'c1 reworded\n\nwith a body',
    ]);
    // Dropped commit's file is gone; the rest exist.
    expect(File(p.join(tmp.path, 'f1.txt')).existsSync(), isFalse);
    for (final f in ['f0.txt', 'f2.txt', 'f3.txt']) {
      expect(File(p.join(tmp.path, f)).existsSync(), isTrue, reason: f);
    }
    // Control dir cleaned up after completion.
    final ctrl = p.join(
        await resolveGitDir(tmp.path), RebaseDriver.ctrlDirName);
    expect(Directory(ctrl).existsSync(), isFalse);
    expect(await detectOpState(tmp.path), RepoOpState.none);
  });

  test('fixup folds without keeping the message', () async {
    final (base, h) = await history(['k1', 'k2']);
    final plan = RebasePlan(baseHash: base, entries: [
      RebaseTodoEntry(hash: h[0], subject: 'k1'),
      RebaseTodoEntry(hash: h[1], subject: 'k2', action: RebaseAction.fixup),
    ]);
    final result = await RebaseDriver(tmp.path).startInteractive(plan);
    expect(result.exitCode, 0, reason: result.stderr);
    expect(await messagesAbove(base), ['k1']);
    expect(File(p.join(tmp.path, 'f1.txt')).existsSync(), isTrue,
        reason: 'fixup keeps the tree change, drops the message');
  });

  test('conflicted rebase pauses, resolves, and a queued reword survives '
      'the --continue boundary', () async {
    // Both commits edit the same line of the same file.
    await write('base.txt', 'base\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
    final base = await head();
    await write('base.txt', 'one\n');
    await g(['commit', '-am', 'k1']);
    final k1 = await head();
    await write('base.txt', 'two\n');
    await g(['commit', '-am', 'k2']);
    final k2 = await head();

    // Drop k1, keep k2 as a reword → replaying k2 onto base conflicts, and
    // the reword's editor invocation happens after the conflict pause.
    final driver = RebaseDriver(tmp.path);
    final start = await driver.startInteractive(RebasePlan(
      baseHash: base,
      entries: [
        RebaseTodoEntry(hash: k1, subject: 'k1', action: RebaseAction.drop),
        RebaseTodoEntry(
            hash: k2,
            subject: 'k2',
            action: RebaseAction.reword,
            newMessage: 'k2 reworded after conflict'),
      ],
    ));
    expect(start.exitCode, isNot(0));
    expect(await detectOpState(tmp.path), RepoOpState.rebasing);
    expect((await snapshot()).hasConflicts, isTrue);

    // Resolve and continue.
    await write('base.txt', 'two\n');
    await g(['add', 'base.txt']);
    final cont = await driver.continueRebase();
    expect(cont.exitCode, 0, reason: cont.stderr);

    expect(await detectOpState(tmp.path), RepoOpState.none);
    expect(await messagesAbove(base), ['k2 reworded after conflict']);
    expect(await File(p.join(tmp.path, 'base.txt')).readAsString(), 'two\n');
  });

  test('abort restores the original HEAD and cleans control state', () async {
    await write('base.txt', 'base\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
    final base = await head();
    await write('base.txt', 'one\n');
    await g(['commit', '-am', 'k1']);
    final k1 = await head();
    await write('base.txt', 'two\n');
    await g(['commit', '-am', 'k2']);
    final original = await head();

    final driver = RebaseDriver(tmp.path);
    final start = await driver.startInteractive(RebasePlan(
      baseHash: base,
      entries: [
        RebaseTodoEntry(hash: k1, subject: 'k1', action: RebaseAction.drop),
        RebaseTodoEntry(hash: original, subject: 'k2'),
      ],
    ));
    expect(start.exitCode, isNot(0)); // conflict pause

    await driver.abort();
    expect(await head(), original);
    expect(await detectOpState(tmp.path), RepoOpState.none);
    final ctrl = p.join(
        await resolveGitDir(tmp.path), RebaseDriver.ctrlDirName);
    expect(Directory(ctrl).existsSync(), isFalse);
  });

  test('validatePlan rejects broken plans', () {
    RebaseTodoEntry e(String h, RebaseAction a, [String? msg]) =>
        RebaseTodoEntry(hash: h, subject: h, action: a, newMessage: msg);
    expect(validatePlan(const RebasePlan(baseHash: 'b', entries: [])),
        isNotNull);
    expect(
        validatePlan(RebasePlan(
            baseHash: 'b', entries: [e('a', RebaseAction.drop)])),
        isNotNull);
    expect(
        validatePlan(RebasePlan(baseHash: 'b', entries: [
          e('a', RebaseAction.drop),
          e('b', RebaseAction.squash),
        ])),
        contains('first kept'));
    expect(
        validatePlan(RebasePlan(
            baseHash: 'b', entries: [e('a', RebaseAction.reword, '')])),
        contains('empty message'));
    expect(
        validatePlan(RebasePlan(baseHash: 'b', entries: [
          e('a', RebaseAction.pick),
          e('b', RebaseAction.squash),
        ])),
        isNull);
  });

  test('candidates command lists base..HEAD oldest-first', () async {
    final (base, _) = await history(['c1', 'c2', 'c3']);
    final r = await GitCli(tmp.path).run(
        ['log', '--reverse', '-z', '--pretty=format:%H%x1f%s', '$base..HEAD']);
    final subjects = r.stdout
        .split('\x00')
        .where((t) => t.isNotEmpty)
        .map((t) => t.split('\x1f')[1])
        .toList();
    expect(subjects, ['c1', 'c2', 'c3']);
  });
}
