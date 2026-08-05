import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/repo/power_providers.dart';
import 'package:branch_pilot/ui/dialogs/mainline_picker_dialog.dart';
import 'package:branch_pilot/ui/graph/commit_graph_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The mainline-picker acceptance test: reverting a merge commit needs `-m`,
/// so [showMainlinePicker] is exercised directly with a [WidgetRef] captured
/// via a `Consumer` wrapper around [BranchPilotApp] — the same sanctioned
/// technique power_ops_test.dart/merge_flow_test.dart/rebase_flow_test.dart
/// use. The graph's right-click "Revert this merge commit…" is thin sugar
/// over this same picker + [PowerOps.revert] call (see
/// commit_graph_view.dart's `_runCherryPickOrRevert`); driving a real
/// secondary-tap through `showMenu` has no reliable widget-test driver, same
/// reasoning as those files' doc comments.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> makeFixture() async {
    final dir =
        await Directory.systemTemp.createTemp('branchpilot_mergerevert_');
    Future<void> g(List<String> a) async {
      final r =
          await Process.run(GitCli.gitExecutable, ['-C', dir.path, ...a]);
      if (r.exitCode != 0) {
        throw StateError('git $a failed: ${r.stderr}');
      }
    }

    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'mergerevert@test.local']);
    await g(['config', 'user.name', 'MergeRevert']);
    await g(['config', 'commit.gpgsign', 'false']);
    await File(p.join(dir.path, 'base.txt')).writeAsString('base\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);

    await g(['checkout', '-b', 'side']);
    await File(p.join(dir.path, 'side.txt')).writeAsString('side content\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'side commit']);

    await g(['checkout', 'main']);
    await File(p.join(dir.path, 'main.txt')).writeAsString('main content\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'main commit']);

    // --no-ff so HEAD really is a 2-parent merge, not a fast-forward.
    await g(['merge', '--no-ff', 'side', '-m', 'merge side']);

    return dir;
  }

  Future<String> head(Directory dir) async {
    final r = await Process.run(
        GitCli.gitExecutable, ['-C', dir.path, 'rev-parse', 'HEAD']);
    return (r.stdout as String).trim();
  }

  Future<List<String>> parentsOf(Directory dir, String hash) async {
    final r = await Process.run(GitCli.gitExecutable,
        ['-C', dir.path, 'show', '-s', '--format=%P', hash]);
    return (r.stdout as String).trim().split(' ');
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
      'mainline picker renders both parents; picking parent 1 and '
      'reverting removes side.txt; cancelling creates nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dir = await makeFixture();
    addTearDown(() => dir.delete(recursive: true));

    final mergeSha = await head(dir);
    final parents = await parentsOf(dir, mergeSha);
    expect(parents, hasLength(2),
        reason: 'sanity check: the fixture HEAD really is a 2-parent merge');
    final p1Short = parents[0].substring(0, 7);
    final p2Short = parents[1].substring(0, 7);

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
    await pumpUntil(tester, () => find.text('merge side').evaluate().isNotEmpty);

    // A mounted descendant of the Navigator — showDialog needs a context
    // inside the app's own tree, not the outer Consumer's (which sits above
    // MaterialApp/Navigator and wouldn't resolve one).
    final graphContext = tester.element(find.byType(CommitGraphView));

    // --- Show the picker, confirm both parent rows render, pick parent 1.
    final pickerFuture = showMainlinePicker(
      graphContext,
      appRef,
      repoPath: dir.path,
      parentHashes: parents,
      operationLabel: 'Revert',
    );
    // showMainlinePicker fetches each parent's subject before opening the
    // dialog, so the first scheduled frame may lag a moment behind the
    // call — pumpUntil (rather than a single pumpAndSettle) rides out that
    // gap instead of assuming the dialog is already up.
    await pumpUntil(tester,
        () => find.byKey(const Key('mainline-confirm')).evaluate().isNotEmpty);

    expect(find.byKey(const Key('mainline-parent-1')), findsOneWidget);
    expect(find.byKey(const Key('mainline-parent-2')), findsOneWidget);
    expect(find.textContaining(p1Short), findsWidgets,
        reason: "parent 1's short hash must be visible in its row");
    expect(find.textContaining(p2Short), findsWidgets,
        reason: "parent 2's short hash must be visible in its row");

    await tester.tap(find.byKey(const Key('mainline-parent-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mainline-confirm')));
    await tester.pumpAndSettle();
    expect(await pickerFuture, 1);

    // --- Drive the revert itself (the context menu is thin sugar over
    // exactly this call — see the file doc comment).
    await PowerOps(dir.path, appRef).revert(mergeSha, mainline: 1);

    await pumpUntil(
        tester, () => find.textContaining('Revert').evaluate().isNotEmpty);
    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);

    final headAfterRevert = await head(dir);
    expect(headAfterRevert, isNot(mergeSha));
    expect(File(p.join(dir.path, 'side.txt')).existsSync(), isFalse,
        reason: 'mainline 1 undoes side\'s contribution to the merge');
    expect(File(p.join(dir.path, 'main.txt')).existsSync(), isTrue);
    final subject = await Process.run(GitCli.gitExecutable,
        ['-C', dir.path, 'log', '-1', '--format=%s']);
    expect((subject.stdout as String).trim(), startsWith('Revert'));

    // --- Cancel path: reopening the picker and cancelling must not touch
    // history at all.
    final cancelFuture = showMainlinePicker(
      graphContext,
      appRef,
      repoPath: dir.path,
      parentHashes: parents,
      operationLabel: 'Revert',
    );
    await pumpUntil(tester,
        () => find.byKey(const Key('mainline-cancel')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const Key('mainline-cancel')));
    await tester.pumpAndSettle();
    expect(await cancelFuture, isNull);
    expect(await head(dir), headAfterRevert,
        reason: 'cancelling the picker must not create any commit');
  });
}
