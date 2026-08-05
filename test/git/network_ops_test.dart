@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The P5 acceptance tests for the fetch/pull/push commands `NetworkOps`
/// runs, exercised directly through `GitCli` against real local `file://`
/// remotes — same spirit as branch_ops_test.dart: drive the exact command
/// sequences without needing a `WidgetRef` (`NetworkOps` needs one;
/// integration_test/remote_flow_test.dart covers it through the UI).
///
/// `file://` URLs (rather than a plain local path) force git's normal
/// transport/protocol machinery, so real progress and ref-update lines land
/// on stderr instead of the near-silent hardlink fast path a bare path
/// argument would take.
void main() {
  late Directory root;
  late Directory bare;
  late Directory workA;

  Future<void> configureUser(String repoPath, String name) async {
    await GitCli(repoPath).run(['config', 'user.email', '$name@test.local']);
    await GitCli(repoPath).run(['config', 'user.name', name]);
    await GitCli(repoPath).run(['config', 'commit.gpgsign', 'false']);
  }

  Future<void> write(String repoPath, String rel, String content) =>
      File(p.join(repoPath, rel)).writeAsString(content, flush: true);

  Future<String> headOid(String repoPath) async =>
      (await GitCli(repoPath).run(['rev-parse', 'HEAD'])).stdout.trim();

  Future<String> revParse(String repoPath, String rev) async =>
      (await GitCli(repoPath).run(['rev-parse', rev])).stdout.trim();

  /// Drives a started process to completion exactly like `NetworkOps` does:
  /// both streams are being consumed *before* awaiting the exit code (so a
  /// chatty command can't block on a full pipe), and their lines are
  /// collected so the tests that care can assert real output came through.
  Future<(int, List<String>)> drive(GitProcess proc) async {
    final stdoutFuture = proc.stdoutLines.toList();
    final stderrFuture = proc.stderrLines.toList();
    final exitCode = await proc.exitCode;
    await stdoutFuture;
    final stderrLines = await stderrFuture;
    return (exitCode, stderrLines);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('branchpilot_netops_');
    bare = Directory(p.join(root.path, 'bare.git'));
    await GitCli(root.path).run(['init', '--bare', '-b', 'main', bare.path]);

    workA = Directory(p.join(root.path, 'workA'));
    await GitCli(root.path).run(['init', '-b', 'main', workA.path]);
    await configureUser(workA.path, 'WorkA');
    await GitCli(workA.path)
        .run(['remote', 'add', 'origin', 'file://${bare.path}']);
    await write(workA.path, 'f.txt', 'base\n');
    await GitCli(workA.path).run(['add', '.']);
    await GitCli(workA.path).run(['commit', '-m', 'base commit']);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
      'push -u sets upstream and reports real ref-update lines over a '
      'file:// transport', () async {
    // The exact command NetworkOps.push() runs when there is no upstream.
    final proc =
        await GitCli(workA.path).start(['push', '-u', 'origin', 'main']);
    final (exitCode, stderrLines) = await drive(proc);

    expect(exitCode, 0);
    expect(stderrLines, isNotEmpty,
        reason: 'a file:// transport should report ref updates on stderr');
    expect(await revParse(bare.path, 'main'), await headOid(workA.path));
  });

  group('fetch / pull against a second clone', () {
    late Directory workB;

    setUp(() async {
      // Seed the bare remote with workA's base commit so there's something
      // for workB to clone.
      await GitCli(workA.path).run(['push', '-u', 'origin', 'main']);

      final cloneParent = await Directory.systemTemp
          .createTemp('branchpilot_netops_cloneparent_');
      addTearDown(() => cloneParent.delete(recursive: true));
      workB = Directory(p.join(cloneParent.path, 'workB'));

      // Per the plan, cloning goes through GitCli.start too. `-C` just
      // needs an existing cwd — clone creates the (not yet existing)
      // target directory itself.
      final cloneProc = await GitCli(cloneParent.path)
          .start(['clone', 'file://${bare.path}', workB.path]);
      final (cloneExit, _) = await drive(cloneProc);
      expect(cloneExit, 0);

      await configureUser(workB.path, 'WorkB');
      await write(workB.path, 'from_b.txt', 'remote change\n');
      await GitCli(workB.path).run(['add', '.']);
      await GitCli(workB.path).run(['commit', '-m', 'remote change']);
      await GitCli(workB.path).run(['push']);
    });

    test('fetch --all --prune streams real lines and updates origin/main',
        () async {
      final proc =
          await GitCli(workA.path).start(['fetch', '--all', '--prune']);
      final (exitCode, stderrLines) = await drive(proc);

      expect(exitCode, 0);
      expect(stderrLines, isNotEmpty,
          reason: 'fetch should report the incoming ref update on stderr');
      expect(await revParse(workA.path, 'origin/main'),
          await headOid(workB.path));
    });

    test('pull --no-edit fast-forwards the worktree and leaves it clean',
        () async {
      final proc = await GitCli(workA.path).start(['pull', '--no-edit']);
      final (exitCode, _) = await drive(proc);

      expect(exitCode, 0);
      expect(await headOid(workA.path), await headOid(workB.path));
      final status = await GitCli(workA.path).run(['status', '--porcelain']);
      expect(status.stdout.trim(), isEmpty);
    });

    test(
        'a plain push fails non-fast-forward after workB amends; '
        '--force-with-lease succeeds', () async {
      // workB rewrites its own head commit, diverging from what the bare
      // remote already has for it.
      await write(workB.path, 'from_b.txt', 'remote change, amended\n');
      await GitCli(workB.path).run(['add', '.']);
      await GitCli(workB.path)
          .run(['commit', '--amend', '-m', 'remote change (amended)']);

      final plainPush = await GitCli(workB.path).start(['push']);
      final (plainExit, _) = await drive(plainPush);
      expect(plainExit, isNot(0));

      final leasePush =
          await GitCli(workB.path).start(['push', '--force-with-lease']);
      final (leaseExit, _) = await drive(leasePush);
      expect(leaseExit, 0);

      expect(await revParse(bare.path, 'main'), await headOid(workB.path));
    });
  });

  test(
      'fetch against a nonexistent local path fails fast with non-empty '
      'stderr', () async {
    final proc = await GitCli(workA.path)
        .start(['fetch', 'file:///nonexistent/xyz-branchpilot']);
    final (exitCode, stderrLines) = await drive(proc);

    expect(exitCode, isNot(0));
    expect(stderrLines, isNotEmpty);
  });
}
