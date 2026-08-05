import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The P8 keyboard-shortcut acceptance test: Space (stage/unstage the
/// selected file), Ctrl+Enter (submit the commit box), and F5 (fetch all
/// remotes) all driven as real synthesized key events against a pumped
/// `BranchPilotApp` — repo_screen.dart's `CallbackShortcuts` needs a real
/// widget tree with real focus, and F5/the commit both need real `WidgetRef`
/// access (`NetworkOps`/`CommitOps`), so this is an integration test rather
/// than a plain widget test (same reasoning as commit_flow_test.dart /
/// remote_flow_test.dart). Also covers the guard the other direction: typing
/// a plain space while the commit subject field has focus must not leak out
/// as a stage/unstage toggle.
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

  Future<String> lastSubject(String repoPath) async {
    final r = await Process.run(
        GitCli.gitExecutable, ['-C', repoPath, 'log', '-1', '--format=%s']);
    return (r.stdout as String).trim();
  }

  /// A repo with a real `file://` remote (so F5 has something to fetch
  /// against without erroring) and one unstaged change to a tracked file
  /// (so Space has something to stage/unstage).
  Future<Directory> makeFixture() async {
    final root =
        await Directory.systemTemp.createTemp('branchpilot_kbshortcuts_');
    final barePath = p.join(root.path, 'bare.git');
    await Process.run(
        GitCli.gitExecutable, ['init', '--bare', '-b', 'main', barePath]);

    final workPath = p.join(root.path, 'work');
    await Process.run(GitCli.gitExecutable, ['init', '-b', 'main', workPath]);
    await configureUser(workPath, 'KbShortcuts');
    await g(workPath, ['remote', 'add', 'origin', 'file://$barePath']);
    final file = File(p.join(workPath, 'f.txt'));
    await file.writeAsString('one\n');
    await g(workPath, ['add', '.']);
    await g(workPath, ['commit', '-m', 'init']);
    await g(workPath, ['push', '-u', 'origin', 'main']);

    // The change Space will stage/unstage.
    await file.writeAsString('one\ntwo\n');
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

  testWidgets(
      'F5 fetches, Space stages/unstages the selected file, typing a space '
      'in the commit box does not leak into a stage toggle, and Ctrl+Enter '
      'commits', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final root = await makeFixture();
    addTearDown(() => root.delete(recursive: true));
    final workPath = p.join(root.path, 'work');

    await tester.pumpWidget(ProviderScope(
      child: BranchPilotApp(initialRepoPaths: [workPath]),
    ));
    await pumpUntil(tester,
        () => find.byTooltip('Fetch all remotes (F5)').evaluate().isNotEmpty);

    // --- F5: fetches all remotes -----------------------------------------
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await pumpUntil(tester, () => find.text('Fetch').evaluate().isNotEmpty);

    // --- Space: stages the selected file ----------------------------------
    await pumpUntil(
        tester,
        () => find
            .textContaining('f.txt', findRichText: true)
            .evaluate()
            .isNotEmpty);
    expect(find.text('UNSTAGED'), findsOneWidget);
    await tester.tap(find.textContaining('f.txt', findRichText: true).first);
    await pumpUntil(
        tester, () => find.textContaining('@@').evaluate().isNotEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await pumpUntil(tester, () => find.text('STAGED').evaluate().isNotEmpty);
    expect(find.text('UNSTAGED'), findsNothing);

    // --- Space again: unstages it back ------------------------------------
    await tester.tap(find.textContaining('f.txt', findRichText: true).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await pumpUntil(tester, () => find.text('UNSTAGED').evaluate().isNotEmpty);
    expect(find.text('STAGED'), findsNothing);

    // --- typing inside the commit subject field is not hijacked -----------
    await tester.tap(find.byKey(const Key('commit-subject')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('commit-subject')), 'feat: typed');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    // No stage side effect leaked out of the text field.
    expect(find.text('UNSTAGED'), findsOneWidget);
    expect(find.text('STAGED'), findsNothing);
    final subjectField =
        tester.widget<TextField>(find.byKey(const Key('commit-subject')));
    expect(subjectField.controller!.text, startsWith('feat: typed'));

    // --- Ctrl+Enter: submits the commit box --------------------------------
    // Something needs to be staged for the commit button to be enabled —
    // reuse the Space shortcut once more, exactly like a real user would.
    await tester.tap(find.textContaining('f.txt', findRichText: true).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await pumpUntil(tester, () => find.text('STAGED').evaluate().isNotEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);

    // Git's own commit-message cleanup trims the trailing space our
    // in-field Space keystroke added above.
    expect(await lastSubject(workPath), 'feat: typed');
  });
}
