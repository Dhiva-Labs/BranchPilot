import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../git/rebase.dart';
import '../../repo/branch_providers.dart';
import '../../repo/rebase_providers.dart';

/// Opens the interactive-rebase todo editor for `baseHash..HEAD` and, if the
/// user starts the rebase, runs it and reports the outcome.
///
/// The dialog itself (see [RebaseEditorBody]) only builds and validates a
/// [RebasePlan]; it pops itself with that plan once the user taps Start.
/// Running the plan happens here, after the dialog is gone — the graph
/// context menu is thin sugar over this same call, and tests invoke it
/// directly (see integration_test/rebase_flow_test.dart).
Future<void> showRebaseEditor(
  BuildContext context,
  WidgetRef ref, {
  required String repoPath,
  required String baseHash,
  required String baseShortLabel,
}) async {
  final plan = await showDialog<RebasePlan>(
    context: context,
    builder: (dialogContext) => _RebaseEditorDialog(
      repoPath: repoPath,
      baseHash: baseHash,
      baseShortLabel: baseShortLabel,
    ),
  );
  if (plan == null || !context.mounted) return;

  final result = await RebaseOps(repoPath, ref).startInteractive(plan);
  if (!context.mounted) return;

  if (result.exitCode == 0) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Rebase complete')));
    return;
  }

  // Nonzero exit: a conflict pause (op state still `rebasing`) is not a
  // failure — the status banner + conflicted rows handle resolution from
  // here. Anything else is a plain failure; surface stderr.
  final opState = await ref.read(repoOpStateProvider(repoPath).future);
  if (!context.mounted) return;
  if (opState == RepoOpState.rebasing) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Rebase paused on a conflict — resolve in the right panel')));
  } else {
    final stderr = result.stderr;
    final shown = stderr.length > 300 ? stderr.substring(0, 300) : stderr;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(shown.trim().isEmpty ? 'Rebase failed' : shown)));
  }
}

class _RebaseEditorDialog extends ConsumerWidget {
  final String repoPath;
  final String baseHash;
  final String baseShortLabel;

  const _RebaseEditorDialog({
    required this.repoPath,
    required this.baseHash,
    required this.baseShortLabel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final candidates =
        ref.watch(rebaseCandidatesProvider((repo: repoPath, base: baseHash)));
    return Dialog(
      child: SizedBox(
        width: 640,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Interactive rebase onto $baseShortLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: switch (candidates) {
                AsyncData(:final value) => value.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('No commits to rebase'),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      )
                    : RebaseEditorBody(
                        baseHash: baseHash,
                        initialEntries: value,
                        onStart: (plan) => Navigator.of(context).pop(plan),
                      ),
                AsyncError(:final error) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('$error',
                          style: TextStyle(color: scheme.error, fontSize: 12)),
                    ),
                  ),
                _ => const Center(child: CircularProgressIndicator()),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The rebase todo editor's content: a reorderable, per-row action editor
/// over the candidate commits. Public (and provider-free) so widget tests can
/// pump it directly with a canned candidate list — see
/// test/ui/rebase_editor_logic_test.dart. [showRebaseEditor] wires the real
/// provider data and the post-Start git call around it.
class RebaseEditorBody extends StatefulWidget {
  /// The commit the plan will be rebased onto. Only used to build the
  /// [RebasePlan] passed to [onStart] — [validatePlan] doesn't consult it.
  final String baseHash;

  /// Candidates in todo order (oldest first, as returned by
  /// rebaseCandidatesProvider — every action defaults to pick).
  final List<RebaseTodoEntry> initialEntries;

  /// Called with the built, oldest-first [RebasePlan] when the user taps
  /// Start with a valid arrangement.
  final void Function(RebasePlan plan) onStart;

  const RebaseEditorBody({
    super.key,
    required this.baseHash,
    required this.initialEntries,
    required this.onStart,
  });

  @override
  State<RebaseEditorBody> createState() => _RebaseEditorBodyState();
}

class _RebaseEditorBodyState extends State<RebaseEditorBody> {
  /// Newest-first — the reverse of todo order — matching how the list is
  /// displayed (see the caption below the list). This is the list the
  /// ReorderableListView edits directly; [_plan] reverses it back to
  /// oldest-first when building the [RebasePlan].
  late List<RebaseTodoEntry> _display;

  @override
  void initState() {
    super.initState();
    _display = widget.initialEntries.reversed.toList();
  }

  RebasePlan get _plan => RebasePlan(
      baseHash: widget.baseHash, entries: _display.reversed.toList());

  String? get _error => validatePlan(_plan);

  // Uses onReorderItem (not the deprecated onReorder): newIndex here is
  // already adjusted for the item's removal, so no manual decrement.
  void _handleReorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _display.removeAt(oldIndex);
      _display.insert(newIndex, item);
    });
  }

  void _setAction(int index, RebaseAction action) {
    setState(() => _display[index] = _display[index].copyWith(action: action));
  }

  Future<void> _openReword(int index) async {
    final entry = _display[index];
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _RewordDialog(
        shortHash: entry.shortHash,
        initialText: entry.newMessage ?? entry.subject,
      ),
    );
    if (result == null) return; // Cancel keeps the previous action.
    setState(() => _display[index] =
        entry.copyWith(action: RebaseAction.reword, newMessage: result));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.initialEntries.length > 100)
          Container(
            width: double.infinity,
            color: Colors.amber.withValues(alpha: 0.16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              'Rebasing ${widget.initialEntries.length} commits — this may '
              'take a while',
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Newest commit on top; applied bottom-up.',
            style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ReorderableListView(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            onReorderItem: _handleReorder,
            children: [
              for (final (i, entry) in _display.indexed)
                _RebaseRow(
                  key: ValueKey(entry.hash),
                  index: i,
                  entry: entry,
                  onActionChanged: (a) {
                    if (a == RebaseAction.reword) {
                      _openReword(i);
                    } else {
                      _setAction(i, a);
                    }
                  },
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'Squash/fixup fold into the commit below them in this list '
            '(the earlier commit, applied first).',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: error == null
                    ? const SizedBox.shrink()
                    : Text(error,
                        style: TextStyle(color: scheme.error, fontSize: 11.5)),
              ),
              FilledButton(
                key: const Key('rebase-start'),
                onPressed: error == null ? () => widget.onStart(_plan) : null,
                child: const Text('Start rebase'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The nested reword dialog. A dedicated StatefulWidget (rather than building
/// the TextEditingController inline in `_openReword` and disposing it right
/// after `showDialog` returns) so the controller's lifecycle is tied to this
/// widget's own dispose() — the dialog route keeps rebuilding the TextField
/// for a few frames during its exit transition even after `showDialog`'s
/// Future has already resolved, which would otherwise use an
/// already-disposed controller.
class _RewordDialog extends StatefulWidget {
  final String shortHash;
  final String initialText;

  const _RewordDialog({required this.shortHash, required this.initialText});

  @override
  State<_RewordDialog> createState() => _RewordDialogState();
}

class _RewordDialogState extends State<_RewordDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reword ${widget.shortHash}'),
      content: SizedBox(
        width: 440,
        child: TextField(
          key: const Key('reword-field'),
          controller: _controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          key: const Key('reword-save'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _RebaseRow extends StatelessWidget {
  final int index;
  final RebaseTodoEntry entry;
  final ValueChanged<RebaseAction> onActionChanged;

  const _RebaseRow({
    super.key,
    required this.index,
    required this.entry,
    required this.onActionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dropped = entry.action == RebaseAction.drop;
    final rewordPreview = entry.action == RebaseAction.reword &&
        (entry.newMessage?.trim().isNotEmpty ?? false);
    final subjectText =
        rewordPreview ? _firstLine(entry.newMessage!) : entry.subject;

    return SizedBox(
      height: 36,
      child: Row(
        children: [
          SizedBox(
            width: 112,
            child: DropdownButton<RebaseAction>(
              key: Key('rebase-action-${entry.shortHash}'),
              value: entry.action,
              isDense: true,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) onActionChanged(v);
              },
              items: [
                for (final a in RebaseAction.values)
                  DropdownMenuItem(
                    value: a,
                    child: Text(
                      a.name,
                      style: TextStyle(
                        fontSize: 12,
                        color: _actionColor(a),
                        decoration:
                            a == RebaseAction.drop ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 66,
            child: Text(
              entry.shortHash,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              subjectText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontStyle: rewordPreview ? FontStyle.italic : FontStyle.normal,
                decoration: dropped ? TextDecoration.lineThrough : null,
                color: dropped
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
                    : null,
              ),
            ),
          ),
          ReorderableDragStartListener(
            key: Key('rebase-drag-${entry.shortHash}'),
            index: index,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Icon(Icons.drag_handle,
                  size: 16, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

Color? _actionColor(RebaseAction a) => switch (a) {
      RebaseAction.pick => null,
      RebaseAction.reword => Colors.lightBlueAccent,
      RebaseAction.squash => Colors.purpleAccent,
      RebaseAction.fixup => Colors.tealAccent,
      RebaseAction.drop => Colors.redAccent,
    };

String _firstLine(String s) {
  final trimmed = s.trimLeft();
  final idx = trimmed.indexOf('\n');
  return (idx < 0 ? trimmed : trimmed.substring(0, idx)).trimRight();
}
