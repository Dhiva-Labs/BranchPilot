import 'dart:io';

import 'package:branch_pilot/app.dart';
import 'package:branch_pilot/git/git_cli.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// The P2 acceptance test: open a repo with one unstaged change, open its
/// diff from the status panel, then stage and unstage the whole file from
/// the diff view's header button. The selection must follow the file into
/// its new section (rather than getting dropped) so the pane badge and
/// action button flip in place.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> makeFixture() async {
    final dir = await Directory.systemTemp.createTemp('branchpilot_staging_');
    Future<void> g(List<String> a) async {
      final r =
          await Process.run(GitCli.gitExecutable, ['-C', dir.path, ...a]);
      if (r.exitCode != 0) {
        throw StateError('git $a failed: ${r.stderr}');
      }
    }

    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'staging@test.local']);
    await g(['config', 'user.name', 'Staging']);
    await g(['config', 'commit.gpgsign', 'false']);

    final lines = List.generate(10, (i) => 'line ${i + 1}');
    final file = File(p.join(dir.path, 'f.txt'));
    await file.writeAsString('${lines.join('\n')}\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'init']);

    lines[4] = 'line 5 CHANGED';
    await file.writeAsString('${lines.join('\n')}\n');
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

  testWidgets('stage and unstage a whole file from the diff view',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = await makeFixture();
    addTearDown(() => repo.delete(recursive: true));

    await tester.pumpWidget(ProviderScope(
      child: BranchPilotApp(initialRepoPaths: [repo.path]),
    ));

    // The unstaged row for f.txt shows up in the status panel.
    await pumpUntil(
        tester,
        () => find
            .textContaining('f.txt', findRichText: true)
            .evaluate()
            .isNotEmpty);

    // Click it: the diff opens in the center pane.
    await tester.tap(find.textContaining('f.txt', findRichText: true).first);
    await pumpUntil(
        tester, () => find.textContaining('@@').evaluate().isNotEmpty);
    expect(find.textContaining('line 5 CHANGED', findRichText: true),
        findsWidgets);

    // Stage the whole file from the diff header; the badge flips to STAGED
    // and the button becomes "Unstage file" without the selection closing.
    await tester.tap(find.text('Stage file'));
    await pumpUntil(tester, () => find.text('STAGED').evaluate().isNotEmpty);

    // Unstage it again; back to UNSTAGED.
    await tester.tap(find.text('Unstage file'));
    await pumpUntil(
        tester, () => find.text('UNSTAGED').evaluate().isNotEmpty);
  });
}
