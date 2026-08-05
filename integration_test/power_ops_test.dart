import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/repo/power_providers.dart';
import 'package:branch_pilot/ui/dialogs/reset_dialog.dart';
import 'package:branch_pilot/ui/graph/commit_graph_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The P7 acceptance tests: the hard-reset dialog is gated by typing the
/// branch name exactly, and a cherry-pick conflict pauses, resolves, and
/// continues entirely through the status panel's sequencer banner.
///
/// Both [showResetDialog] and [PowerOps.cherryPick] are invoked directly
/// with a `WidgetRef` captured via a `Consumer` wrapper around
/// [BranchPilotApp] — the same sanctioned technique merge_flow_test.dart and
/// rebase_flow_test.dart use. The graph's right-click context menu is thin
/// sugar over these exact calls (see commit_graph_view.dart's
/// `_showRowContextMenu`); driving a real secondary-tap through `showMenu`
/// has no reliable widget-test driver, same reasoning as those files' doc
/// comments.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> g(Directory dir, List<String> a) async {
    final r = await Process.run(GitCli.gitExecutable, ['-C', dir.path, ...a]);
    if (r.exitCode != 0) {
      throw StateError('git $a failed: ${r.stderr}');
    }
  }

  Future<String> head(Directory dir) async {
    final r = await Process.run(
        GitCli.gitExecutable, ['-C', dir.path, 'rev-parse', 'HEAD']);
    return (r.stdout as String).trim();
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

  testWidgets('hard reset is gated by typed branch name', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir =
        await Directory.systemTemp.createTemp('branchpilot_powerops_reset_');
    addTearDown(() => dir.delete(recursive: true));

    await g(dir, ['init', '-b', 'main']);
    await g(dir, ['config', 'user.email', 'reset@test.local']);
    await g(dir, ['config', 'user.name', 'ResetFlow']);
    await g(dir, ['config', 'commit.gpgsign', 'false']);
    await File(p.join(dir.path, 'f.txt')).writeAsString('one\n');
    await g(dir, ['add', '.']);
    await g(dir, ['commit', '-m', 'first']);
    final firstHash = await head(dir);
    await File(p.join(dir.path, 'f.txt')).writeAsString('two\n');
    await g(dir, ['commit', '-am', 'second']);

    late WidgetRef appRef;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(
        builder: (context, ref, child) {
          appRef = ref;
          return child!;
        },
        child: BranchPilotApp(initialRepoPaths: [dir.path]),
      ),
    ));

    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);
    await pumpUntil(tester, () => find.text('second').evaluate().isNotEmpty);

    // A mounted descendant of the Navigator, matching rebase_flow_test.dart's
    // technique — the outer Consumer sits above MaterialApp/Navigator and
    // wouldn't resolve a usable context for showDialog.
    final graphContext = tester.element(find.byType(CommitGraphView));

    final resetFuture = showResetDialog(
      graphContext,
      appRef,
      repoPath: dir.path,
      hash: firstHash,
      branchName: 'main',
    );
    await tester.pumpAndSettle();

    // Mixed is the default; select hard.
    await tester.tap(find.byKey(const Key('reset-hard')));
    await tester.pumpAndSettle();

    Finder confirmButton() => find.byKey(const Key('reset-confirm'));
    expect(confirmButton(), findsOneWidget);
    expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNull);

    await tester.enterText(
        find.byKey(const Key('reset-confirm-field')), 'nope');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNull,
        reason: 'the wrong branch name must keep the button disabled');

    await tester.enterText(
        find.byKey(const Key('reset-confirm-field')), 'main');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirmButton()).onPressed, isNotNull,
        reason: 'the exact branch name enables the button');

    await tester.tap(confirmButton());
    await tester.pumpAndSettle();
    await resetFuture;

    await pumpUntil(tester, () => find.text('second').evaluate().isEmpty);
    expect(await head(dir), firstHash);
  });

  testWidgets('cherry-pick conflict resolves through the banner',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp
        .createTemp('branchpilot_powerops_cherrypick_');
    addTearDown(() => dir.delete(recursive: true));

    await g(dir, ['init', '-b', 'main']);
    await g(dir, ['config', 'user.email', 'cherrypick@test.local']);
    await g(dir, ['config', 'user.name', 'CherryPickFlow']);
    await g(dir, ['config', 'commit.gpgsign', 'false']);
    await File(p.join(dir.path, 'base.txt')).writeAsString('base\n');
    await g(dir, ['add', '.']);
    await g(dir, ['commit', '-m', 'base']);

    await g(dir, ['checkout', '-b', 'side']);
    await File(p.join(dir.path, 'base.txt')).writeAsString('side change\n');
    await g(dir, ['commit', '-am', 'side change']);
    final sideHash = await head(dir);

    await g(dir, ['checkout', 'main']);
    await File(p.join(dir.path, 'base.txt')).writeAsString('main change\n');
    await g(dir, ['commit', '-am', 'main change']);

    late WidgetRef appRef;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(
        builder: (context, ref, child) {
          appRef = ref;
          return child!;
        },
        child: BranchPilotApp(initialRepoPaths: [dir.path]),
      ),
    ));

    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);
    await pumpUntil(
        tester, () => find.text('main change').evaluate().isNotEmpty);

    // The context menu's "Cherry-pick this commit" is sugar over this exact
    // call — the banner flow is what's under test here.
    await PowerOps(dir.path, appRef).cherryPick(sideHash);

    await pumpUntil(tester,
        () => find.text('Cherry-pick in progress').evaluate().isNotEmpty);
    Finder continueButton() => find.byKey(const Key('seq-continue'));
    expect(continueButton(), findsOneWidget);
    expect(tester.widget<FilledButton>(continueButton()).onPressed, isNull);

    // Resolve externally, the same technique rebase_flow_test.dart and
    // test/git/rebase_driver_test.dart use: write the resolved content and
    // stage it via a plain git process, outside the app.
    await File(p.join(dir.path, 'base.txt')).writeAsString('resolved\n');
    await g(dir, ['add', 'base.txt']);

    await pumpUntil(tester,
        () => tester.widget<FilledButton>(continueButton()).onPressed != null);
    await tester.tap(continueButton());
    await pumpUntil(tester,
        () => find.text('Cherry-pick in progress').evaluate().isEmpty);

    await pumpUntil(
        tester, () => find.text('side change').evaluate().isNotEmpty);
  });
}
