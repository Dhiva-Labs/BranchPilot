import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../repo/commit_providers.dart';

/// Prompts for which parent of a merge commit is the "mainline" (`-m <n>`,
/// 1-based) before a cherry-pick or revert — see power_providers.dart's
/// `PowerOps.cherryPick`/`revert` doc comments for why a merge commit needs
/// this at all. [parentHashes] is the merge commit's parent list in git's
/// own order (first parent first); the returned index is 1-based to match
/// `-m` directly. Returns null if the user cancels, in which case the caller
/// must not run any git command.
///
/// Each parent's subject (via [commitMetaProvider]) is fetched and awaited
/// before the dialog is shown — one cheap `git show` per parent (almost
/// always just 2), which keeps the dialog itself free of any per-row loading
/// state. A failed lookup falls back to the short hash alone rather than
/// blocking or crashing (see [commitMetaProvider]'s own null-on-failure
/// behavior).
Future<int?> showMainlinePicker(
  BuildContext context,
  WidgetRef ref, {
  required String repoPath,
  required List<String> parentHashes,
  required String operationLabel,
}) async {
  final subjects = await Future.wait(parentHashes.map((hash) async {
    final meta =
        await ref.read(commitMetaProvider((repo: repoPath, hash: hash)).future);
    return meta?.subject;
  }));
  if (!context.mounted) return null;
  return showDialog<int>(
    context: context,
    builder: (_) => _MainlinePickerDialog(
      operationLabel: operationLabel,
      parentHashes: parentHashes,
      subjects: subjects,
    ),
  );
}

String _shortHash(String hash) => hash.length >= 7 ? hash.substring(0, 7) : hash;

class _MainlinePickerDialog extends StatefulWidget {
  final String operationLabel;
  final List<String> parentHashes;
  final List<String?> subjects;

  const _MainlinePickerDialog({
    required this.operationLabel,
    required this.parentHashes,
    required this.subjects,
  });

  @override
  State<_MainlinePickerDialog> createState() => _MainlinePickerDialogState();
}

class _MainlinePickerDialogState extends State<_MainlinePickerDialog> {
  // Parent 1 (the branch the merge was made into) is the conventional
  // mainline and the sane default selection.
  int _selected = 1;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.operationLabel} a merge commit'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.operationLabel} on a merge needs to know which '
              'parent line of history is the mainline — changes introduced '
              'by the OTHER parent are what get carried over. Parent 1 is '
              "usually right: it's the branch the merge was made into.",
            ),
            const SizedBox(height: 12),
            RadioGroup<int>(
              groupValue: _selected,
              onChanged: (v) => setState(() => _selected = v ?? _selected),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, hash) in widget.parentHashes.indexed)
                    RadioListTile<int>(
                      key: Key('mainline-parent-${i + 1}'),
                      value: i + 1,
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        widget.subjects[i] == null
                            ? 'Parent ${i + 1} — ${_shortHash(hash)}'
                            : 'Parent ${i + 1} — ${_shortHash(hash)}  '
                                '${widget.subjects[i]}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('mainline-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('mainline-confirm'),
          onPressed: () => Navigator.of(context).pop(_selected),
          child: Text(widget.operationLabel),
        ),
      ],
    );
  }
}
