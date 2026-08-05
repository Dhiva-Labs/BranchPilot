@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/parsers/porcelain_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// End-to-end parser checks against real `git status` output from a
/// disposable fixture repository.
void main() {
  late Directory tmp;

  Future<void> g(List<String> args) async => GitCli(tmp.path).run(args);

  Future<StatusSnapshot> snapshot() async {
    final r = await GitCli(tmp.path)
        .run(['status', '--porcelain=v2', '--branch', '-z']);
    return parsePorcelainV2(r.stdout);
  }

  Future<void> write(String rel, String content) =>
      File(p.join(tmp.path, rel)).writeAsString(content);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_fixture_');
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'fixture@test.local']);
    await g(['config', 'user.name', 'Fixture']);
    await g(['config', 'commit.gpgsign', 'false']);
    await write('a.txt', 'alpha\n');
    await write('b.txt', 'beta\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('discoverToplevel resolves subdirectories and rejects non-repos',
      () async {
    final sub = Directory(p.join(tmp.path, 'sub'))..createSync();
    expect(await GitCli.discoverToplevel(sub.path),
        await GitCli.discoverToplevel(tmp.path));
    final plain = await Directory.systemTemp.createTemp('branchpilot_plain_');
    addTearDown(() => plain.delete(recursive: true));
    expect(await GitCli.discoverToplevel(plain.path), isNull);
  });

  test('mixed staged/unstaged/untracked/renamed state parses correctly',
      () async {
    await write('a.txt', 'alpha 2\n'); // unstaged M
    await write('c.txt', 'gamma\n'); // staged A
    await g(['add', 'c.txt']);
    await g(['mv', 'b.txt', 'b_renamed.txt']); // staged R
    await write('untracked.txt', 'new\n'); // untracked

    final s = await snapshot();
    expect(s.branch.head, 'main');
    expect(s.unstaged.map((e) => e.path), contains('a.txt'));
    expect(
        s.staged.map((e) => e.path), containsAll(['c.txt', 'b_renamed.txt']));
    final rename = s.entries.firstWhere((e) => e.path == 'b_renamed.txt');
    expect(rename.indexState, FileState.renamed);
    expect(rename.origPath, 'b.txt');
    expect(s.untracked.map((e) => e.path), contains('untracked.txt'));
  });

  test('merge conflict produces unmerged entries', () async {
    await g(['checkout', '-b', 'feature']);
    await write('a.txt', 'feature change\n');
    await g(['commit', '-am', 'feature edit']);
    await g(['checkout', 'main']);
    await write('a.txt', 'main change\n');
    await g(['commit', '-am', 'main edit']);
    final merge = await GitCli(tmp.path).run(['merge', 'feature'], check: false);
    expect(merge.exitCode, isNot(0));

    final s = await snapshot();
    expect(s.hasConflicts, isTrue);
    final e = s.conflicted.single;
    expect(e.path, 'a.txt');
    expect(e.xy, 'UU');
    expect(s.branch.head, 'main');
  });

  test('ahead/behind against an upstream', () async {
    final remote = await Directory.systemTemp.createTemp('branchpilot_remote_');
    addTearDown(() => remote.delete(recursive: true));
    await GitCli(remote.path).run(['init', '--bare', '-b', 'main']);
    await g(['remote', 'add', 'origin', remote.path]);
    await g(['push', '-u', 'origin', 'main']);
    await write('a.txt', 'local ahead\n');
    await g(['commit', '-am', 'ahead commit']);

    final s = await snapshot();
    expect(s.branch.upstream, 'origin/main');
    expect(s.branch.ahead, 1);
    expect(s.branch.behind, 0);
  });

  test('detached HEAD is reported', () async {
    await g(['checkout', '--detach', 'HEAD']);
    final s = await snapshot();
    expect(s.branch.detached, isTrue);
    expect(s.branch.oid, isNotNull);
  });

  test('path with spaces round-trips through real git', () async {
    Directory(p.join(tmp.path, 'my dir')).createSync();
    await write('my dir/my file.txt', 'spaced\n');
    final s = await snapshot();
    expect(s.untracked.map((e) => e.path), contains('my dir/'));
  });
}
