@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/repo/repo_watcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  RepoWatcher? watcher;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_watch_');
    final g = GitCli(tmp.path);
    await g.run(['init', '-b', 'main']);
    await g.run(['config', 'user.email', 'w@test.local']);
    await g.run(['config', 'user.name', 'Watcher']);
    await g.run(['config', 'commit.gpgsign', 'false']);
    await File(p.join(tmp.path, 'f.txt')).writeAsString('x\n');
    await g.run(['add', '.']);
    await g.run(['commit', '-m', 'base']);
  });

  tearDown(() async {
    watcher?.dispose();
    watcher = null;
    await tmp.delete(recursive: true);
  });

  Future<Completer<void>> armedWatcher() async {
    final fired = Completer<void>();
    watcher = RepoWatcher(tmp.path, onChange: () {
      if (!fired.isCompleted) fired.complete();
    });
    await watcher!.start();
    await watcher!.ready;
    return fired;
  }

  test('external worktree edit fires onChange (debounced)', () async {
    final fired = await armedWatcher();
    await File(p.join(tmp.path, 'f.txt')).writeAsString('changed\n');
    await fired.future.timeout(const Duration(seconds: 10));
  });

  test('index change via git add fires onChange', () async {
    await File(p.join(tmp.path, 'f.txt')).writeAsString('staged soon\n');
    final fired = await armedWatcher();
    await GitCli(tmp.path).run(['add', 'f.txt']);
    await fired.future.timeout(const Duration(seconds: 10));
  });

  test('branch switch (HEAD change) fires onChange', () async {
    await GitCli(tmp.path).run(['branch', 'other']);
    final fired = await armedWatcher();
    await GitCli(tmp.path).run(['checkout', 'other']);
    await fired.future.timeout(const Duration(seconds: 10));
  });
}
