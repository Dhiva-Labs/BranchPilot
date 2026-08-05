import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../repo/task_providers.dart';

/// Thin strip along the bottom of the center pane showing in-flight and
/// recently finished fetch/pull/push tasks, with live progress lines. Empty
/// until the first task begins; finished tasks stay until dismissed.
class TaskStrip extends ConsumerWidget {
  final String repoPath;

  const TaskStrip({super.key, required this.repoPath});

  static const _visibleCap = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksProvider(repoPath));
    if (tasks.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final visible = tasks.take(_visibleCap).toList();
    final overflow = tasks.length - visible.length;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border(
            top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final task in visible)
            _TaskRow(repoPath: repoPath, task: task),
          if (overflow > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 5),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('+$overflow more',
                    style:
                        TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
              ),
            ),
        ],
      ),
    );
  }
}

class _TaskRow extends ConsumerWidget {
  final String repoPath;
  final GitTask task;

  const _TaskRow({required this.repoPath, required this.task});

  /// Same amber hint whether the watchdog flagged a hung `running` task, or
  /// a `failed` task's tail matches the known auth-failure shapes.
  bool get _showAuthHint => switch (task.state) {
        GitTaskState.running => task.maybeWaitingAuth,
        GitTaskState.failed =>
          authFailurePattern.hasMatch(task.errorTail.join('\n')),
        _ => false,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isRunning = task.state == GitTaskState.running;
    return InkWell(
      onTap: task.state == GitTaskState.failed
          ? () => _showErrorDialog(context)
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
        child: Row(
          children: [
            _StateIcon(state: task.state),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: Text(task.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    task.lastLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant),
                  ),
                  if (_showAuthHint)
                    Text(
                      'Waiting on authentication? Run this once in a '
                      'terminal, then retry.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 10.5, color: Colors.amberAccent.shade200),
                    ),
                ],
              ),
            ),
            if (isRunning)
              IconButton(
                tooltip: 'Cancel',
                icon: const Icon(Icons.cancel, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => NetworkOps(repoPath, ref).cancel(task.id),
              )
            else
              IconButton(
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () =>
                    ref.read(tasksProvider(repoPath).notifier).dismiss(task.id),
              ),
          ],
        ),
      ),
    );
  }

  void _showErrorDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text('${task.label} failed'),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: SingleChildScrollView(
                child: SelectableText(
                  task.errorTail.join('\n'),
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StateIcon extends StatelessWidget {
  final GitTaskState state;

  const _StateIcon({required this.state});

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      GitTaskState.running => const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      GitTaskState.succeeded =>
        const Icon(Icons.check_circle, size: 14, color: Colors.greenAccent),
      GitTaskState.failed =>
        const Icon(Icons.error, size: 14, color: Colors.redAccent),
      GitTaskState.cancelled =>
        const Icon(Icons.block, size: 14, color: Colors.grey),
    };
  }
}
