import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../git/git_cli.dart';
import '../git/git_dirs.dart';
import '../git/rebase.dart';
import 'providers.dart';

/// Commits that would be replayed by `git rebase -i <base>`: base..HEAD,
/// oldest first (todo order).
final rebaseCandidatesProvider = FutureProvider.autoDispose
    .family<List<RebaseTodoEntry>, ({String repo, String base})>(
        (ref, arg) async {
  final r = await GitCli(arg.repo).run([
    'log',
    '--reverse',
    '-z',
    '--pretty=format:%H%x1f%s',
    '${arg.base}..HEAD',
  ]);
  final entries = <RebaseTodoEntry>[];
  for (final token in r.stdout.split('\x00')) {
    final t = token.startsWith('\n') ? token.substring(1) : token;
    if (t.isEmpty) continue;
    final f = t.split('\x1f');
    if (f.length < 2) continue;
    entries.add(RebaseTodoEntry(hash: f[0], subject: f.sublist(1).join(' ')));
  }
  return entries;
});

/// Drives `git rebase -i` non-interactively via helper editors (see
/// lib/git/rebase.dart). Ref-free so fixture tests can exercise the exact
/// execution path; [RebaseOps] wraps it with the UI refresh.
///
/// The control directory lives inside the gitdir so a conflict pause — or
/// even an app restart mid-rebase — keeps the queued reword messages
/// available to `--continue`.
class RebaseDriver {
  final String repo;

  RebaseDriver(this.repo);

  GitCli get _git => GitCli(repo);

  static const ctrlDirName = 'branchpilot-rebase';

  Future<String> _ctrlPath() async =>
      p.join(await resolveGitDir(repo), ctrlDirName);

  Future<Map<String, String>> _editorEnv() async {
    final ctrl = await _ctrlPath();
    if (!File(p.join(ctrl, 'editor.sh')).existsSync()) {
      // No stored control state (e.g. rebase started outside the app, or the
      // state was cleaned): accept git's prepared messages as-is.
      return const {'GIT_EDITOR': 'true', 'GIT_SEQUENCE_EDITOR': 'true'};
    }
    return {
      'GIT_SEQUENCE_EDITOR': 'sh "${p.join(ctrl, 'seq.sh')}"',
      'GIT_EDITOR': 'sh "${p.join(ctrl, 'editor.sh')}"',
    };
  }

  Future<void> _writeControlDir(RebasePlan plan) async {
    final ctrl = await _ctrlPath();
    final dir = Directory(ctrl);
    if (dir.existsSync()) await dir.delete(recursive: true);
    await Directory(p.join(ctrl, 'msgs')).create(recursive: true);
    await File(p.join(ctrl, 'todo')).writeAsString(buildTodoFile(plan));
    final (queue, payloads) = buildEditorQueue(plan);
    await File(p.join(ctrl, 'queue')).writeAsString('${queue.join('\n')}\n');
    for (final e in payloads.entries) {
      await File(p.join(ctrl, 'msgs', e.key)).writeAsString(e.value);
    }
    await File(p.join(ctrl, 'seq.sh'))
        .writeAsString(sequenceEditorScript(ctrl));
    await File(p.join(ctrl, 'editor.sh')).writeAsString(editorScript(ctrl));
  }

  Future<void> _cleanupIfDone() async {
    if (await detectOpState(repo) != RepoOpState.rebasing) {
      final ctrl = Directory(await _ctrlPath());
      if (ctrl.existsSync()) await ctrl.delete(recursive: true);
    }
  }

  /// Starts the interactive rebase. Nonzero exit + op state `rebasing` means
  /// a conflict pause (resolve, then [continueRebase]); nonzero without the
  /// rebase state is a plain failure (dirty worktree, invalid base, ...).
  Future<GitResult> startInteractive(RebasePlan plan) async {
    final problem = validatePlan(plan);
    if (problem != null) {
      throw GitException('rebase -i', -1, problem);
    }
    await _writeControlDir(plan);
    final result = await _git.run(
      // --empty=drop: reordering/squashing can make a commit redundant;
      // dropping beats interrupting the whole run. --no-autosquash: the
      // prepared todo IS the plan — no config surprises.
      ['rebase', '-i', '--empty=drop', '--no-autosquash', plan.baseHash],
      check: false,
      environment: await _editorEnv(),
    );
    await _cleanupIfDone();
    return result;
  }

  Future<GitResult> continueRebase() async {
    final result = await _git.run(
      ['rebase', '--continue'],
      check: false,
      environment: await _editorEnv(),
    );
    await _cleanupIfDone();
    return result;
  }

  Future<GitResult> skipCommit() async {
    final result = await _git.run(
      ['rebase', '--skip'],
      check: false,
      environment: await _editorEnv(),
    );
    await _cleanupIfDone();
    return result;
  }

  Future<void> abort() async {
    await _git.run(['rebase', '--abort']);
    final ctrl = Directory(await _ctrlPath());
    if (ctrl.existsSync()) await ctrl.delete(recursive: true);
  }
}

/// UI-facing wrapper: every operation refreshes the status snapshot (which
/// cascades to the graph and op-state banner).
class RebaseOps {
  final RebaseDriver _driver;
  final WidgetRef ref;

  RebaseOps(String repo, this.ref) : _driver = RebaseDriver(repo);

  Future<void> _refresh() =>
      ref.read(repoStatusProvider(_driver.repo).notifier).refresh();

  Future<GitResult> startInteractive(RebasePlan plan) async {
    final r = await _driver.startInteractive(plan);
    await _refresh();
    return r;
  }

  Future<GitResult> continueRebase() async {
    final r = await _driver.continueRebase();
    await _refresh();
    return r;
  }

  Future<GitResult> skipCommit() async {
    final r = await _driver.skipCommit();
    await _refresh();
    return r;
  }

  Future<void> abort() async {
    await _driver.abort();
    await _refresh();
  }
}
