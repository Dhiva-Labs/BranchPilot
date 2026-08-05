import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/repo/branch_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The P4 acceptance test: two branches edit the same line of the same file,
/// merging one into the other conflicts, and the conflict is resolved
/// entirely through the real UI — the banner, the per-file resolve actions,
/// and Continue.
///
/// Triggering the merge itself is the one step driven directly through
/// `BranchOps` rather than a right-click context menu: `showMenu` positioned
/// off a `GestureDetector.onSecondaryTapDown` has no reliable widget-test
/// driver (there's no synthesized secondary-button tap gesture with a
/// screen position that `showMenu` can anchor to), so exercising it here
/// would be flaky rather than meaningful. Everything downstream of the
/// merge landing in a conflicted state — the banner, conflicted-row
/// actions, and Continue — is driven exactly as a user would.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> makeFixture() async {
    final dir = await Directory.systemTemp.createTemp('branchpilot_mergeflow_');
    Future<void> g(List<String> a) async {
      final r =
          await Process.run(GitCli.gitExecutable, ['-C', dir.path, ...a]);
      if (r.exitCode != 0) {
        throw StateError('git $a failed: ${r.stderr}');
      }
    }

    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'merge@test.local']);
    await g(['config', 'user.name', 'MergeFlow']);
    await g(['config', 'commit.gpgsign', 'false']);
    await File(p.join(dir.path, 'f.txt')).writeAsString('base\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);

    await g(['checkout', '-b', 'feature']);
    await File(p.join(dir.path, 'f.txt')).writeAsString('feature change\n');
    await g(['commit', '-am', 'feature edit']);

    await g(['checkout', 'main']);
    await File(p.join(dir.path, 'f.txt')).writeAsString('main change\n');
    await g(['commit', '-am', 'main edit']);

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

  testWidgets('resolve a merge conflict through the conflict-resolution UI',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = await makeFixture();
    addTearDown(() => repo.delete(recursive: true));

    late WidgetRef appRef;
    await tester.pumpWidget(ProviderScope(
      child: Consumer(
        builder: (context, ref, child) {
          appRef = ref;
          return child!;
        },
        child: BranchPilotApp(initialRepoPaths: [repo.path]),
      ),
    ));

    // App settles on main, clean, with both branches listed.
    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);
    await pumpUntil(tester, () => find.text('feature').evaluate().isNotEmpty);

    // The merge trigger only — see the class doc comment.
    await BranchOps(repo.path, appRef).mergeBranch('feature');

    // Banner appears; Continue starts disabled (f.txt still conflicted).
    await pumpUntil(
        tester, () => find.text('Merge in progress').evaluate().isNotEmpty);
    Finder continueButton() => find.byKey(const Key('merge-continue'));
    expect(continueButton(), findsOneWidget);
    expect(tester.widget<FilledButton>(continueButton()).onPressed, isNull);

    // The conflicted row for f.txt is visible in the status panel.
    expect(find.textContaining('f.txt', findRichText: true), findsWidgets);

    // Resolve via the row's "Take ours" action.
    await tester.tap(find.byTooltip('Take ours'));
    await pumpUntil(tester,
        () => tester.widget<FilledButton>(continueButton()).onPressed != null);

    // Continue concludes the merge.
    await tester.tap(continueButton());
    await pumpUntil(
        tester, () => find.text('Merge in progress').evaluate().isEmpty);

    // The graph now shows the new merge commit (default message "Merge
    // branch 'feature'" — see git's fmt-merge-msg).
    await pumpUntil(
        tester, () => find.textContaining('Merge').evaluate().isNotEmpty);
  });
}
