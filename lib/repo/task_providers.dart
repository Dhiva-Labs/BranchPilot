import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_cli.dart';
import 'branch_providers.dart';
import 'providers.dart';

/// Cap on how many output lines are retained per task (oldest dropped first).
const _tailCap = 50;

/// Lifecycle state of one fetch/pull/push invocation.
enum GitTaskState { running, succeeded, failed, cancelled }

/// One entry in the task strip. Kept in [TasksNotifier]'s list — even once
/// finished — until the user dismisses it or clears the strip, so a
/// completed push doesn't vanish out from under them mid-glance.
class GitTask {
  final int id;
  final String label;
  final GitTaskState state;

  /// Most recent stdout/stderr line seen. Git rewrites progress lines in
  /// place with `\r`, so only the latest matters for a "live" display.
  final String lastLine;

  /// The last (capped) lines of output, oldest first. Doubles as the detail
  /// shown for a failed task and as the input to the auth-failure heuristic.
  final List<String> errorTail;

  /// True once the no-output watchdog has fired for a still-running task —
  /// probably means git is blocked on a credential prompt that
  /// GIT_TERMINAL_PROMPT=0 didn't manage to turn into a fast failure.
  final bool maybeWaitingAuth;

  const GitTask({
    required this.id,
    required this.label,
    required this.state,
    this.lastLine = '',
    this.errorTail = const [],
    this.maybeWaitingAuth = false,
  });

  GitTask copyWith({
    GitTaskState? state,
    String? lastLine,
    List<String>? errorTail,
    bool? maybeWaitingAuth,
  }) =>
      GitTask(
        id: id,
        label: label,
        state: state ?? this.state,
        lastLine: lastLine ?? this.lastLine,
        errorTail: errorTail ?? this.errorTail,
        maybeWaitingAuth: maybeWaitingAuth ?? this.maybeWaitingAuth,
      );
}

/// Per-repository list of git tasks (fetch/pull/push), most recent first.
///
/// Kept alive for as long as something watches it. In practice that's
/// [TaskStrip] (see ui/panels/task_strip.dart), which is unconditionally
/// mounted in [RepoScreen] whenever a repo tab is open — plain autoDispose is
/// enough, since the watch never actually stops while an operation could be
/// running. No manual `ref.keepAlive()` needed.
class TasksNotifier extends AutoDisposeFamilyNotifier<List<GitTask>, String> {
  int _nextId = 0;

  @override
  List<GitTask> build(String arg) => const [];

  /// Starts tracking a new task in the `running` state and returns its id.
  int begin(String label) {
    final id = _nextId++;
    state = [GitTask(id: id, label: label, state: GitTaskState.running), ...state];
    return id;
  }

  /// Records one line of output: becomes the live [GitTask.lastLine], and is
  /// appended to the capped tail buffer.
  void progress(int id, String line) {
    _update(id, (t) {
      final tail = [...t.errorTail, line];
      return t.copyWith(
        lastLine: line,
        errorTail:
            tail.length > _tailCap ? tail.sublist(tail.length - _tailCap) : tail,
      );
    });
  }

  /// Moves a task to a terminal state. [cancelled] wins over [ok].
  void finish(int id, {required bool ok, bool cancelled = false}) {
    final next = cancelled
        ? GitTaskState.cancelled
        : (ok ? GitTaskState.succeeded : GitTaskState.failed);
    _update(id, (t) => t.copyWith(state: next));
  }

  /// Flags a still-running task as possibly blocked on a credential prompt.
  void markMaybeAuth(int id) {
    _update(id, (t) => t.copyWith(maybeWaitingAuth: true));
  }

  /// Removes one task regardless of its state.
  void dismiss(int id) {
    state = state.where((t) => t.id != id).toList();
  }

  /// Drops every task that has reached a terminal state, keeping only the
  /// ones still running.
  void clearFinished() {
    state = state.where((t) => t.state == GitTaskState.running).toList();
  }

  void _update(int id, GitTask Function(GitTask) f) {
    state = [
      for (final t in state)
        if (t.id == id) f(t) else t,
    ];
  }
}

final tasksProvider = NotifierProvider.autoDispose
    .family<TasksNotifier, List<GitTask>, String>(TasksNotifier.new);

/// Auth-failure heuristic: with GIT_TERMINAL_PROMPT=0, a blocked credential
/// prompt surfaces as one of these fast stderr failures instead of hanging.
/// Shared between [NetworkOps] (not currently needed there, but keeps the
/// pattern in one place) and the task strip's failed-row hint.
final RegExp authFailurePattern = RegExp(
  'terminal prompts disabled|could not read Username|Permission denied|'
  'Authentication failed',
  caseSensitive: false,
);

/// Tracks a running [GitProcess] for a task so [NetworkOps.cancel] can kill
/// it. [cancelled] records whether a kill was actually requested — kill() on
/// an already-exited process is a harmless no-op, so this flag (not the
/// resulting exit code) is what decides `cancelled` vs `failed`.
class _TrackedProcess {
  final GitProcess process;
  bool cancelled = false;

  _TrackedProcess(this.process);
}

/// Fetch/pull/push, invoked from the repo header. Every operation streams
/// output into [tasksProvider] as it runs and always refreshes
/// [repoStatusProvider] once it settles — success, failure, or cancellation.
class NetworkOps {
  final String repo;
  final WidgetRef ref;

  NetworkOps(this.repo, this.ref);

  /// taskId -> tracked process, scoped by repo so ids (which restart at 0 in
  /// each [TasksNotifier] family instance) never collide across repos.
  static final Map<String, Map<int, _TrackedProcess>> _processes = {};

  TasksNotifier get _tasks => ref.read(tasksProvider(repo).notifier);

  Future<void> _refreshStatus() =>
      ref.read(repoStatusProvider(repo).notifier).refresh();

  Future<int> fetchAll() => _start(['fetch', '--all', '--prune'], 'Fetch');

  /// Merge conflicts from the pull land in the working tree the same as any
  /// other merge — the existing P4 conflict banner picks them up via the
  /// status refresh below; nothing extra is needed here.
  Future<int> pull() => _start(['pull', '--no-edit'], 'Pull');

  Future<int> push({bool forceWithLease = false}) async {
    final branch = ref.read(repoStatusProvider(repo)).valueOrNull?.branch;
    if (branch == null || branch.head == null) {
      throw GitException('push', -1, 'cannot push a detached HEAD');
    }
    if (branch.upstream == null) {
      final remotes = await ref.read(remotesProvider(repo).future);
      if (remotes.isEmpty) {
        throw GitException('push', -1, 'no remote configured');
      }
      final remote = remotes.contains('origin') ? 'origin' : remotes.first;
      return _start(['push', '-u', remote, branch.head!], 'Push (set upstream)');
    }
    return _start(
      ['push', if (forceWithLease) '--force-with-lease'],
      forceWithLease ? 'Force push' : 'Push',
    );
  }

  /// Pushes a single tag ref, e.g. from the left panel's tag menu. Same
  /// remote-resolution rule as the no-upstream branch of [push]: prefer
  /// `origin`, else whichever remote is configured first.
  Future<int> pushTag(String tag) async {
    final remotes = await ref.read(remotesProvider(repo).future);
    if (remotes.isEmpty) {
      throw GitException('push', -1, 'no remote configured');
    }
    final remote = remotes.contains('origin') ? 'origin' : remotes.first;
    return _start(['push', remote, tag], 'Push tag $tag');
  }

  /// Kills the process backing [taskId], if it is still running. The task
  /// itself transitions to `cancelled` once its exit code lands, in [_start].
  void cancel(int taskId) {
    final tracked = _processes[repo]?[taskId];
    if (tracked == null) return;
    tracked.cancelled = true;
    tracked.process.kill();
  }

  Future<int> _start(List<String> args, String label) async {
    final tasks = _tasks;
    final id = tasks.begin(label);
    final repoProcesses = _processes.putIfAbsent(repo, () => {});

    GitProcess proc;
    try {
      proc = await GitCli(repo)
          .start(args, environment: const {'GIT_TERMINAL_PROMPT': '0'});
    } on GitException catch (e) {
      tasks.progress(id, e.stderr.isEmpty ? e.toString() : e.stderr);
      tasks.finish(id, ok: false);
      await _refreshStatus();
      return -1;
    }
    final tracked = _TrackedProcess(proc);
    repoProcesses[id] = tracked;

    var lineArrived = false;
    var settled = false;
    final authTimer = Timer(const Duration(seconds: 25), () {
      if (!settled && !lineArrived) tasks.markMaybeAuth(id);
    });

    void onLine(String line) {
      lineArrived = true;
      tasks.progress(id, line);
    }

    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    proc.stdoutLines.listen(onLine,
        onDone: stdoutDone.complete, onError: (_) => stdoutDone.complete());
    proc.stderrLines.listen(onLine,
        onDone: stderrDone.complete, onError: (_) => stderrDone.complete());

    int exitCode;
    try {
      exitCode = await proc.exitCode;
    } finally {
      settled = true;
      authTimer.cancel();
    }
    await Future.wait([stdoutDone.future, stderrDone.future]);

    repoProcesses.remove(id);
    tasks.finish(id, ok: exitCode == 0, cancelled: tracked.cancelled);
    await _refreshStatus();
    return exitCode;
  }
}
