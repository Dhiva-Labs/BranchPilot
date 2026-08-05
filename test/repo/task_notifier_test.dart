import 'package:branch_pilot/repo/task_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure `TasksNotifier` tests via a bare `ProviderContainer` — no widget
/// tree, no git process, just the state machine `NetworkOps`/`TaskStrip`
/// share. A no-op `listen` keeps each autoDispose family instance alive for
/// the container's lifetime (the same role `TaskStrip`'s permanent watch
/// plays in the real app), so tests can freely interleave `read`s without
/// relying on disposal never having a chance to fire.
void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    container.listen(tasksProvider('x'), (_, _) {});
  });

  tearDown(() => container.dispose());

  TasksNotifier notifier([String repo = 'x']) =>
      container.read(tasksProvider(repo).notifier);
  List<GitTask> tasks([String repo = 'x']) =>
      container.read(tasksProvider(repo));

  test('begin adds a running task carrying the given label', () {
    final id = notifier().begin('Fetch');
    final list = tasks();
    expect(list, hasLength(1));
    expect(list.single.id, id);
    expect(list.single.label, 'Fetch');
    expect(list.single.state, GitTaskState.running);
    expect(list.single.lastLine, isEmpty);
    expect(list.single.errorTail, isEmpty);
    expect(list.single.maybeWaitingAuth, isFalse);
  });

  test('each new task is inserted at the front (most recent first)', () {
    notifier().begin('Fetch');
    notifier().begin('Pull');
    expect(tasks().map((t) => t.label).toList(), ['Pull', 'Fetch']);
  });

  test('task ids are unique within one repo notifier', () {
    final a = notifier().begin('Fetch');
    final b = notifier().begin('Pull');
    final c = notifier().begin('Push');
    expect({a, b, c}, hasLength(3));
  });

  test('progress sets lastLine and appends to the tail in order', () {
    final id = notifier().begin('Fetch');
    notifier().progress(id, 'line 1');
    notifier().progress(id, 'line 2');
    final task = tasks().single;
    expect(task.lastLine, 'line 2');
    expect(task.errorTail, ['line 1', 'line 2']);
  });

  test('progress caps the tail at 50 lines, dropping the oldest first', () {
    final id = notifier().begin('Fetch');
    for (var i = 0; i < 60; i++) {
      notifier().progress(id, 'line $i');
    }
    final task = tasks().single;
    expect(task.errorTail, hasLength(50));
    expect(task.errorTail.first, 'line 10');
    expect(task.errorTail.last, 'line 59');
    expect(task.lastLine, 'line 59');
  });

  test('progress on one task never touches another task in the same list',
      () {
    final fetchId = notifier().begin('Fetch');
    final pullId = notifier().begin('Pull');
    notifier().progress(pullId, 'pulling...');
    final byId = {for (final t in tasks()) t.id: t};
    expect(byId[pullId]!.lastLine, 'pulling...');
    expect(byId[fetchId]!.lastLine, isEmpty);
  });

  test('finish(ok: true) transitions to succeeded', () {
    final id = notifier().begin('Fetch');
    notifier().finish(id, ok: true);
    expect(tasks().single.state, GitTaskState.succeeded);
  });

  test('finish(ok: false) transitions to failed', () {
    final id = notifier().begin('Fetch');
    notifier().finish(id, ok: false);
    expect(tasks().single.state, GitTaskState.failed);
  });

  test('finish(cancelled: true) wins over ok: true', () {
    final id = notifier().begin('Fetch');
    notifier().finish(id, ok: true, cancelled: true);
    expect(tasks().single.state, GitTaskState.cancelled);
  });

  test('markMaybeAuth flags a running task without changing its state', () {
    final id = notifier().begin('Push');
    notifier().markMaybeAuth(id);
    final task = tasks().single;
    expect(task.maybeWaitingAuth, isTrue);
    expect(task.state, GitTaskState.running);
  });

  test('dismiss removes a task regardless of its state', () {
    final runningId = notifier().begin('Fetch');
    final finishedId = notifier().begin('Pull');
    notifier().finish(finishedId, ok: true);

    notifier().dismiss(finishedId);
    expect(tasks().map((t) => t.id).toList(), [runningId]);

    notifier().dismiss(runningId);
    expect(tasks(), isEmpty);
  });

  test('clearFinished drops every terminal task but keeps running ones', () {
    final runningId = notifier().begin('Fetch');
    final succeededId = notifier().begin('Pull');
    final failedId = notifier().begin('Push');
    final cancelledId = notifier().begin('Push (set upstream)');
    notifier().finish(succeededId, ok: true);
    notifier().finish(failedId, ok: false);
    notifier().finish(cancelledId, ok: false, cancelled: true);

    notifier().clearFinished();

    expect(tasks().map((t) => t.id).toList(), [runningId]);
    expect(tasks().single.state, GitTaskState.running);
  });

  test('separate repos get independent task lists', () {
    container.listen(tasksProvider('a'), (_, _) {});
    container.listen(tasksProvider('b'), (_, _) {});
    container.read(tasksProvider('a').notifier).begin('Fetch');
    expect(tasks('a'), hasLength(1));
    expect(tasks('b'), isEmpty);
  });
}
