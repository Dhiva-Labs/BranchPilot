import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/rebase.dart';
import 'package:branch_pilot/ui/graph/commit_graph_view.dart';
import 'package:branch_pilot/ui/rebase/rebase_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The P6 acceptance test: an interactive rebase (reorder implicit in the
/// newest-first display, drop, reword) is built and run entirely through the
/// rebase editor UI, and a conflicted rebase pauses, resolves, and continues
/// through the status panel's banner.
///
/// [showRebaseEditor] is called directly with a [WidgetRef] captured via a
/// `Consumer` wrapper around [BranchPilotApp] — the same sanctioned technique
/// as merge_flow_test.dart uses for `BranchOps`. The graph's right-click
/// context menu is thin sugar over this exact call (see
/// commit_graph_view.dart's `_showRowContextMenu`); driving a real secondary-
/// tap through `showMenu` has no reliable widget-test driver, same reasoning
/// as merge_flow_test.dart's doc comment. Selecting dropdown actions is done
/// by invoking the found `DropdownButton`'s `onChanged` directly rather than
/// tapping through the overlay menu — the overlay can contain more than one
/// row's worth of matching option text once several rows have non-default
/// actions, and this keeps the test deterministic.
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

  /// Directly invokes the (already-found) DropdownButton's onChanged, rather
  /// than tapping through the popup route — see the file doc comment.
  void selectAction(
      WidgetTester tester, String shortHash, RebaseAction action) {
    final dropdown = tester.widget<DropdownButton<RebaseAction>>(
        find.byKey(Key('rebase-action-$shortHash')));
    dropdown.onChanged!(action);
  }

  testWidgets(
      'reorder + drop + reword a rebase entirely through the editor UI',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir =
        await Directory.systemTemp.createTemp('branchpilot_rebaseflow_');
    addTearDown(() => dir.delete(recursive: true));

    await g(dir, ['init', '-b', 'main']);
    await g(dir, ['config', 'user.email', 'rebaseflow@test.local']);
    await g(dir, ['config', 'user.name', 'RebaseFlow']);
    await g(dir, ['config', 'commit.gpgsign', 'false']);
    await File(p.join(dir.path, 'base.txt')).writeAsString('base\n');
    await g(dir, ['add', '.']);
    await g(dir, ['commit', '-m', 'base']);
    final base = await head(dir);

    final hashes = <String>[];
    for (final (i, subject) in ['c1', 'c2', 'c3'].indexed) {
      // Every commit adds its own file so a reorder/drop never conflicts.
      await File(p.join(dir.path, 'f$i.txt')).writeAsString('$subject\n');
      await g(dir, ['add', '.']);
      await g(dir, ['commit', '-m', subject]);
      hashes.add(await head(dir));
    }
    final c1Short = hashes[0].substring(0, 7);
    final c2Short = hashes[1].substring(0, 7);

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
    await pumpUntil(tester, () => find.text('c3').evaluate().isNotEmpty);
    expect(find.text('c2'), findsOneWidget);
    expect(find.text('c1'), findsOneWidget);

    // A mounted descendant of the Navigator — showDialog needs a context
    // inside the app's own tree, not the outer Consumer's (which sits above
    // MaterialApp/Navigator and wouldn't resolve one).
    final graphContext = tester.element(find.byType(CommitGraphView));

    final editorFuture = showRebaseEditor(
      graphContext,
      appRef,
      repoPath: dir.path,
      baseHash: base,
      baseShortLabel: 'base',
    );
    await tester.pumpAndSettle();

    // Drop c2.
    selectAction(tester, c2Short, RebaseAction.drop);
    await tester.pump();

    // Reword c1.
    selectAction(tester, c1Short, RebaseAction.reword);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('reword-field')), 'c1 via UI rebase');
    await tester.tap(find.byKey(const Key('reword-save')));
    await tester.pumpAndSettle();

    // Valid plan: Start is enabled.
    final startButton = find.byKey(const Key('rebase-start'));
    expect(tester.widget<FilledButton>(startButton).onPressed, isNotNull);

    await tester.tap(startButton);
    await tester.pumpAndSettle();
    await editorFuture;

    await pumpUntil(
        tester, () => find.text('c1 via UI rebase').evaluate().isNotEmpty);
    expect(find.text('c3'), findsOneWidget);
    expect(find.text('c2'), findsNothing);
    expect(find.text('c1'), findsNothing);
    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);

    final log = await Process.run(
        GitCli.gitExecutable, ['-C', dir.path, 'log', '--format=%s']);
    final subjects =
        (log.stdout as String).trim().split('\n').where((s) => s.isNotEmpty);
    expect(subjects, ['c3', 'c1 via UI rebase', 'base']);
  });

  testWidgets(
      'a conflicted rebase pauses, resolves and continues through the status panel',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp
        .createTemp('branchpilot_rebaseflow_conflict_');
    addTearDown(() => dir.delete(recursive: true));

    await g(dir, ['init', '-b', 'main']);
    await g(dir, ['config', 'user.email', 'rebaseflow2@test.local']);
    await g(dir, ['config', 'user.name', 'RebaseFlow2']);
    await g(dir, ['config', 'commit.gpgsign', 'false']);
    await File(p.join(dir.path, 'base.txt')).writeAsString('base\n');
    await g(dir, ['add', '.']);
    await g(dir, ['commit', '-m', 'base']);
    final base = await head(dir);
    await File(p.join(dir.path, 'base.txt')).writeAsString('one\n');
    await g(dir, ['commit', '-am', 'k1']);
    final k1 = await head(dir);
    await File(p.join(dir.path, 'base.txt')).writeAsString('two\n');
    await g(dir, ['commit', '-am', 'k2']);
    final k1Short = k1.substring(0, 7);

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
    await pumpUntil(tester, () => find.text('k2').evaluate().isNotEmpty);

    final graphContext = tester.element(find.byType(CommitGraphView));
    final editorFuture = showRebaseEditor(
      graphContext,
      appRef,
      repoPath: dir.path,
      baseHash: base,
      baseShortLabel: 'base',
    );
    await tester.pumpAndSettle();

    // Drop k1, keep k2 (pick) → replaying k2 directly onto base conflicts.
    selectAction(tester, k1Short, RebaseAction.drop);
    await tester.pump();

    await tester.tap(find.byKey(const Key('rebase-start')));
    await tester.pumpAndSettle();
    await editorFuture;

    await pumpUntil(
        tester, () => find.text('Rebase in progress').evaluate().isNotEmpty);
    Finder continueButton() => find.byKey(const Key('rebase-continue'));
    expect(continueButton(), findsOneWidget);
    expect(tester.widget<FilledButton>(continueButton()).onPressed, isNull);

    // Resolve externally (the same technique test/git/rebase_driver_test.dart
    // uses): write the intended content and stage it.
    await File(p.join(dir.path, 'base.txt')).writeAsString('two\n');
    await g(dir, ['add', 'base.txt']);

    await pumpUntil(tester,
        () => tester.widget<FilledButton>(continueButton()).onPressed != null);
    await tester.tap(continueButton());
    await pumpUntil(
        tester, () => find.text('Rebase in progress').evaluate().isEmpty);

    await pumpUntil(tester, () => find.text('k2').evaluate().isNotEmpty);
    expect(find.text('k1'), findsNothing);
  });
}
