import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/repo/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The P4 acceptance test for the left panel's own dialogs: create a branch
/// (checking it out by default) and push/apply a stash, both driven entirely
/// through the real UI.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> makeFixture() async {
    final dir =
        await Directory.systemTemp.createTemp('branchpilot_branchstash_');
    Future<void> g(List<String> a) async {
      final r =
          await Process.run(GitCli.gitExecutable, ['-C', dir.path, ...a]);
      if (r.exitCode != 0) {
        throw StateError('git $a failed: ${r.stderr}');
      }
    }

    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'branchstash@test.local']);
    await g(['config', 'user.name', 'BranchStash']);
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

  testWidgets('create-branch dialog, then stash push and apply', (tester) async {
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

    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);

    // --- Create branch: tap '+', type a name, confirm. Checkout defaults on.
    await tester.tap(find.byKey(const Key('create-branch')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.enterText(
        find.byKey(const Key('branch-name-field')), 'feat-x');
    await tester.pump();
    await tester.tap(find.byKey(const Key('branch-create-confirm')));

    await pumpUntil(tester, () => find.text('feat-x').evaluate().isNotEmpty);
    await pumpUntil(
        tester,
        () =>
            appRef.read(repoStatusProvider(repo.path)).valueOrNull?.branch.head ==
            'feat-x');

    // --- Stash push: dirty the file externally, tap '+', type a message.
    await File(p.join(repo.path, 'f.txt')).writeAsString('one\ntwo\n');
    await pumpUntil(tester, () => find.text('UNSTAGED').evaluate().isNotEmpty);

    final stashButton = find.byKey(const Key('stash-push'));
    await pumpUntil(tester,
        () => tester.widget<IconButton>(stashButton).onPressed != null);
    await tester.tap(stashButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.enterText(
        find.byKey(const Key('stash-message-field')), 'wip thing');
    await tester.pump();
    await tester.tap(find.byKey(const Key('stash-confirm')));

    await pumpUntil(
        tester, () => find.text('Working tree clean').evaluate().isNotEmpty);
    await pumpUntil(
        tester,
        () => find
            .textContaining('wip thing', findRichText: true)
            .evaluate()
            .isNotEmpty);

    // --- Apply the stash back via its row menu.
    await tester.tap(find.byIcon(Icons.more_vert));
    await pumpUntil(tester, () => find.text('Apply').evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 300)); // let the menu settle
    await tester.tap(find.text('Apply'));

    await pumpUntil(tester, () => find.text('UNSTAGED').evaluate().isNotEmpty);
  });
}
