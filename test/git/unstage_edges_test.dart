@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/parsers/porcelain_status.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Pins the unstage command choices used by WorkingTreeOps:
/// `git reset -q` works where `git restore --staged` does not (unborn HEAD),
/// and a staged rename needs both paths reset.
void main() {
  late Directory tmp;

  Future<void> g(List<String> args) async => GitCli(tmp.path).run(args);

  Future<StatusSnapshot> snapshot() async {
    final r = await GitCli(tmp.path)
        .run(['status', '--porcelain=v2', '--branch', '-z']);
    return parsePorcelainV2(r.stdout);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_unstage_');
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'u@test.local']);
    await g(['config', 'user.name', 'Unstage']);
    await g(['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('unstage on an unborn HEAD (before the first commit)', () async {
    await File(p.join(tmp.path, 'a.txt')).writeAsString('x\n');
    await g(['add', 'a.txt']);
    expect((await snapshot()).staged, hasLength(1));

    await g(['reset', '-q', '--', 'a.txt']); // what unstageFile runs
    final s = await snapshot();
    expect(s.staged, isEmpty);
    expect(s.untracked.single.path, 'a.txt');
  });

  test('unstage-all on an unborn HEAD', () async {
    await File(p.join(tmp.path, 'a.txt')).writeAsString('x\n');
    await File(p.join(tmp.path, 'b.txt')).writeAsString('y\n');
    await g(['add', '-A']);
    await g(['reset', '-q']); // what unstageAll runs
    final s = await snapshot();
    expect(s.staged, isEmpty);
    expect(s.untracked, hasLength(2));
  });

  test('unstaging a rename resets both sides of the rename', () async {
    await File(p.join(tmp.path, 'old.txt')).writeAsString('content\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
    await g(['mv', 'old.txt', 'new.txt']);
    final staged = (await snapshot()).staged.single;
    expect(staged.origPath, 'old.txt');

    // what unstageFile(path, origPath:) runs
    await g(['reset', '-q', '--', staged.path, staged.origPath!]);
    final s = await snapshot();
    expect(s.staged, isEmpty, reason: 'no half-staged rename left behind');
    expect(s.unstaged.map((e) => e.path), contains('old.txt'));
    expect(s.untracked.map((e) => e.path), contains('new.txt'));
  });
}
