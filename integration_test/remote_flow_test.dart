import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The P5 acceptance test: a full fetch -> pull -> push cycle driven
/// entirely through the UI, against a local bare `file://` fixture remote
/// (a real transport, not the near-instant local hardlink path a plain path
/// argument would take) — the header's Fetch/Pull/Push controls and their
/// ahead/behind tooltips, plus the task strip, all need to track the real
/// repo state as it changes both from taps and from a plain external
/// process changing things underneath the app (workB's push, and a "local
/// change" written directly into workA's worktree).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> g(String repoPath, List<String> args) async {
    final r =
        await Process.run(GitCli.gitExecutable, ['-C', repoPath, ...args]);
    if (r.exitCode != 0) {
      throw StateError('git $args in $repoPath failed: ${r.stderr}');
    }
  }

  Future<void> configureUser(String repoPath, String name) async {
    await g(repoPath, ['config', 'user.email', '$name@test.local']);
    await g(repoPath, ['config', 'user.name', name]);
    await g(repoPath, ['config', 'commit.gpgsign', 'false']);
  }

  Future<String> revParse(String repoPath, String rev) async {
    final r = await Process.run(
        GitCli.gitExecutable, ['-C', repoPath, 'rev-parse', rev]);
    return (r.stdout as String).trim();
  }

  /// bare remote + workA (base commit already pushed, as if `git push -u`
  /// had been run from a terminal before the app was ever opened) + workB
  /// (cloned from the same remote, with one commit already pushed back as
  /// "remote change") — everything workA needs to discover by fetching.
  Future<Directory> makeFixture() async {
    final root =
        await Directory.systemTemp.createTemp('branchpilot_remoteflow_');
    final barePath = p.join(root.path, 'bare.git');
    await Process.run(
        GitCli.gitExecutable, ['init', '--bare', '-b', 'main', barePath]);

    final workAPath = p.join(root.path, 'workA');
    await Process.run(GitCli.gitExecutable, ['init', '-b', 'main', workAPath]);
    await configureUser(workAPath, 'WorkA');
    await g(workAPath, ['remote', 'add', 'origin', 'file://$barePath']);
    await File(p.join(workAPath, 'f.txt')).writeAsString('base\n');
    await g(workAPath, ['add', '.']);
    await g(workAPath, ['commit', '-m', 'base commit']);
    await g(workAPath, ['push', '-u', 'origin', 'main']);

    final workBPath = p.join(root.path, 'workB');
    await Process.run(
        GitCli.gitExecutable, ['clone', 'file://$barePath', workBPath]);
    await configureUser(workBPath, 'WorkB');
    await File(p.join(workBPath, 'from_b.txt'))
        .writeAsString('remote change\n');
    await g(workBPath, ['add', '.']);
    await g(workBPath, ['commit', '-m', 'remote change']);
    await g(workBPath, ['push']);

    return root;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (condition()) return;
    }
    fail('condition not met within $timeout');
  }

  testWidgets('fetch, pull, and push through the UI against a local remote',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final root = await makeFixture();
    addTearDown(() => root.delete(recursive: true));
    final workAPath = p.join(root.path, 'workA');
    final barePath = p.join(root.path, 'bare.git');

    await tester.pumpWidget(ProviderScope(
      child: BranchPilotApp(initialRepoPaths: [workAPath]),
    ));

    // App settles with the header visible; workA hasn't fetched yet, so
    // Pull/Push show their plain (no ahead/behind) tooltips.
    await pumpUntil(
        tester, () => find.byTooltip('Pull').evaluate().isNotEmpty);

    // Fetch discovers workB's push as one commit behind on origin/main.
    await tester.tap(find.byKey(const Key('fetch-button')));
    await pumpUntil(
        tester, () => find.byTooltip('Pull (behind 1)').evaluate().isNotEmpty);

    // The task strip keeps the finished Fetch row until dismissed.
    expect(find.text('Fetch'), findsOneWidget);

    // Pull brings the commit in: the graph shows it, and the behind tooltip
    // reverts to plain "Pull".
    await tester.tap(find.byKey(const Key('pull-button')));
    await pumpUntil(
        tester, () => find.text('remote change').evaluate().isNotEmpty);
    await pumpUntil(
        tester, () => find.byTooltip('Pull').evaluate().isNotEmpty);

    // An external change (as if made from a terminal) puts workA one ahead;
    // the file watcher should pick it up on its own, no UI interaction.
    await File(p.join(workAPath, 'local.txt'))
        .writeAsString('local change\n');
    await g(workAPath, ['add', '.']);
    await g(workAPath, ['commit', '-m', 'local change']);
    await pumpUntil(
        tester, () => find.byTooltip('Push (ahead 1)').evaluate().isNotEmpty);

    // Push sends it: the tooltip reverts to plain "Push" once ahead is back
    // to 0, and the bare remote's main ref now matches workA's HEAD.
    await tester.tap(find.byKey(const Key('push-button')));
    await pumpUntil(
        tester, () => find.byTooltip('Push').evaluate().isNotEmpty);

    expect(await revParse(barePath, 'main'), await revParse(workAPath, 'HEAD'));
    expect(find.text('Push'), findsWidgets);
  });
}
