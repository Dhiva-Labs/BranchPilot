import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real app on the Linux embedder: opens a fixture repo from a
/// startup argument, then edits a file externally and expects the status
/// panel to refresh on its own (the P0 acceptance criterion).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> makeFixture({String prefix = 'branchpilot_itest_'}) async {
    final dir = await Directory.systemTemp.createTemp(prefix);
    Future<void> g(List<String> a) async {
      final r =
          await Process.run(GitCli.gitExecutable, ['-C', dir.path, ...a]);
      if (r.exitCode != 0) {
        throw StateError('git $a failed: ${r.stderr}');
      }
    }

    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'itest@test.local']);
    await g(['config', 'user.name', 'ITest']);
    await g(['config', 'commit.gpgsign', 'false']);
    await File(p.join(dir.path, 'hello.txt')).writeAsString('hello\n');
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

  testWidgets('opens a repo and live-updates on external edits',
      (tester) async {
    SharedPreferences.setMockInitialValues({}); // don't touch real prefs
    final repo = await makeFixture();
    addTearDown(() => repo.delete(recursive: true));

    await tester.pumpWidget(ProviderScope(
      child: BranchPilotApp(initialRepoPaths: [repo.path]),
    ));

    // Repo opens: header shows the fixture basename, clean working tree.
    await pumpUntil(tester,
        () => find.text('Working tree clean').evaluate().isNotEmpty);
    expect(find.textContaining(p.basename(repo.path)), findsWidgets);
    expect(find.text('main'), findsWidgets);

    // External modification → unstaged section appears without any UI action.
    await File(p.join(repo.path, 'hello.txt')).writeAsString('changed\n');
    await pumpUntil(
        tester,
        () => find
            .textContaining('hello.txt', findRichText: true)
            .evaluate()
            .isNotEmpty);
    expect(find.text('UNSTAGED'), findsOneWidget);

    // External untracked file → untracked section appears.
    await File(p.join(repo.path, 'fresh.txt')).writeAsString('new\n');
    await pumpUntil(
        tester,
        () => find
            .textContaining('fresh.txt', findRichText: true)
            .evaluate()
            .isNotEmpty);
    expect(find.text('UNTRACKED'), findsOneWidget);
  });

  testWidgets('opens two repos in tabs and switches between them',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repoA = await makeFixture(prefix: 'branchpilot_repo_a_');
    final repoB = await makeFixture(prefix: 'branchpilot_repo_b_');
    addTearDown(() => repoA.delete(recursive: true));
    addTearDown(() => repoB.delete(recursive: true));
    // Make repo B dirty so the two repos are visually distinguishable.
    await File(p.join(repoB.path, 'dirty.txt')).writeAsString('x\n');

    await tester.pumpWidget(ProviderScope(
      child: BranchPilotApp(initialRepoPaths: [repoA.path, repoB.path]),
    ));

    final baseA = p.basename(repoA.path);
    final baseB = p.basename(repoB.path);

    // Both tabs present; B (opened last) is active and shows its untracked
    // file.
    await pumpUntil(tester, () => find.text('UNTRACKED').evaluate().isNotEmpty);
    expect(find.text(baseA), findsWidgets);
    expect(find.text(baseB), findsWidgets);
    expect(
        find.textContaining('dirty.txt', findRichText: true), findsOneWidget);

    // Switch to tab A → clean working tree, B's file gone from view.
    await tester.tap(find.text(baseA).first);
    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);
    expect(find.text('UNTRACKED'), findsNothing);
  });
}
