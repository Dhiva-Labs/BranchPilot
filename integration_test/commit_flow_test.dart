import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The P3 acceptance test: stage an externally-modified file from its
/// per-row Stage button, commit it from the commit box, then amend that
/// commit with a new message — all driven through the real widget tree
/// (CommitOps needs a WidgetRef, which only a pumped app can supply).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> makeFixture() async {
    final dir =
        await Directory.systemTemp.createTemp('branchpilot_commitflow_');
    Future<void> g(List<String> a) async {
      final r =
          await Process.run(GitCli.gitExecutable, ['-C', dir.path, ...a]);
      if (r.exitCode != 0) {
        throw StateError('git $a failed: ${r.stderr}');
      }
    }

    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'commitflow@test.local']);
    await g(['config', 'user.name', 'CommitFlow']);
    await g(['config', 'commit.gpgsign', 'false']);
    await File(p.join(dir.path, 'f.txt')).writeAsString('one\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'init']);
    return dir;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (condition()) return;
    }
    fail('condition not met within $timeout');
  }

  testWidgets('stage, commit, then amend from the commit box', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = await makeFixture();
    addTearDown(() => repo.delete(recursive: true));

    await tester.pumpWidget(ProviderScope(
      child: BranchPilotApp(initialRepoPaths: [repo.path]),
    ));

    // Starts clean; then an external edit produces an unstaged row.
    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);
    await File(p.join(repo.path, 'f.txt')).writeAsString('one\ntwo\n');
    await pumpUntil(
        tester,
        () => find
            .textContaining('f.txt', findRichText: true)
            .evaluate()
            .isNotEmpty);
    expect(find.text('UNSTAGED'), findsOneWidget);

    // Stage it from the row's own Stage button (not the row itself, which
    // would open the diff view instead).
    await tester.tap(find.byTooltip('Stage').first);
    await pumpUntil(tester, () => find.text('STAGED').evaluate().isNotEmpty);

    // Enter a subject and commit.
    await tester.enterText(
        find.byKey(const Key('commit-subject')), 'feat: first change');
    await tester.pump();
    await tester.tap(find.byKey(const Key('commit-button')));
    await pumpUntil(
        tester,
        () =>
            find.text('Working tree clean').evaluate().isNotEmpty &&
            find.text('feat: first change').evaluate().isNotEmpty);

    // Amend leg: checking the toggle prefills the subject from HEAD (both
    // fields were cleared by the commit that just succeeded).
    await tester.tap(find.byKey(const Key('amend-toggle')));
    await pumpUntil(tester, () {
      final field =
          tester.widget<TextField>(find.byKey(const Key('commit-subject')));
      return field.controller!.text == 'feat: first change';
    });

    // Tapping the checkbox moved focus away from the subject field; refocus
    // it explicitly before entering the new text (entering text again on a
    // field that isn't focused is a known-flaky pattern).
    await tester.tap(find.byKey(const Key('commit-subject')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('commit-subject')),
        'feat: first change amended');
    await tester.pump();
    await tester.tap(find.byKey(const Key('commit-button')));
    await pumpUntil(tester,
        () => find.text('feat: first change amended').evaluate().isNotEmpty);
    expect(find.text('feat: first change'), findsNothing);

    // Still exactly two commits: the fixture's base 'init' plus the amended
    // one — amend must replace, not add.
    final count = await Process.run(GitCli.gitExecutable,
        ['-C', repo.path, 'rev-list', '--count', 'HEAD']);
    expect((count.stdout as String).trim(), '2');
  });
}
