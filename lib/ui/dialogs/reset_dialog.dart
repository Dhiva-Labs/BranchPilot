import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../repo/power_providers.dart';

/// Runs [op], showing any thrown error in a SnackBar instead of letting it
/// escape. Same pattern as left_panel.dart / status_panel.dart's `_runOp`.
Future<void> _runOp(BuildContext context, Future<void> Function() op) async {
  try {
    await op();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Opens the reset-mode dialog for [branchName] (the current branch —
/// resetting a detached HEAD isn't offered) onto [hash], and runs the reset
/// if the user confirms. Shared by the graph's context menu and, in tests,
/// invoked directly (see integration_test/power_ops_test.dart) since a real
/// secondary-tap has no reliable widget-test driver — same reasoning as
/// commit_graph_view.dart's other dialogs.
Future<void> showResetDialog(
  BuildContext context,
  WidgetRef ref, {
  required String repoPath,
  required String hash,
  required String branchName,
}) async {
  final mode = await showDialog<String>(
    context: context,
    builder: (_) => _ResetDialog(branchName: branchName),
  );
  if (mode == null || !context.mounted) return;
  await _runOp(
      context, () => PowerOps(repoPath, ref).reset(hash, mode: mode));
}

class _ResetDialog extends StatefulWidget {
  final String branchName;

  const _ResetDialog({required this.branchName});

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  String _mode = 'mixed';
  final _confirmController = TextEditingController();

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  /// Soft/mixed enable immediately; hard requires the branch name typed
  /// exactly, since it discards work with no way back through the app.
  bool get _confirmed =>
      _mode != 'hard' || _confirmController.text == widget.branchName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text('Reset ${widget.branchName} to here'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioGroup<String>(
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v ?? _mode),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const RadioListTile<String>(
                    key: Key('reset-soft'),
                    value: 'soft',
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Soft'),
                    subtitle: Text(
                        'Move the branch only — index and working tree stay '
                        'exactly as they are.'),
                  ),
                  const RadioListTile<String>(
                    key: Key('reset-mixed'),
                    value: 'mixed',
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Mixed'),
                    subtitle: Text(
                        'Move the branch and reset the index — working tree '
                        'stays as it is.'),
                  ),
                  RadioListTile<String>(
                    key: const Key('reset-hard'),
                    value: 'hard',
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Hard'),
                    subtitle: Text(
                        'Move the branch and discard all index and working '
                        'tree changes.',
                        style: TextStyle(color: scheme.error)),
                  ),
                ],
              ),
            ),
            if (_mode == 'hard') ...[
              const SizedBox(height: 4),
              Text('Type the branch name to enable.',
                  style: TextStyle(fontSize: 11.5, color: scheme.error)),
              const SizedBox(height: 6),
              TextField(
                key: const Key('reset-confirm-field'),
                controller: _confirmController,
                autofocus: true,
                decoration: InputDecoration(hintText: widget.branchName),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          key: const Key('reset-confirm'),
          style: _mode == 'hard'
              ? FilledButton.styleFrom(backgroundColor: Colors.redAccent)
              : null,
          onPressed: _confirmed ? () => Navigator.of(context).pop(_mode) : null,
          child: const Text('Reset'),
        ),
      ],
    );
  }
}
