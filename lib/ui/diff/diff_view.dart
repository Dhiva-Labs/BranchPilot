import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../git/parsers/unified_diff.dart';
import '../../repo/diff_providers.dart';
import '../dialogs/file_history_dialog.dart';
import 'hunks_view.dart';

/// Runs [op], showing any thrown error in a SnackBar instead of letting it
/// escape — git failures (a hunk that no longer applies, a permission
/// error, ...) are surfaced, not crashes.
Future<void> _runOp(BuildContext context, Future<void> Function() op) async {
  try {
    await op();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Center-pane diff viewer for whichever file is selected in the status
/// panel. The parent only shows this widget when a selection exists, but it
/// stays defensive: a selection can be cleared out from under it (e.g. the
/// file it's showing loses its last change in that section).
class DiffView extends ConsumerWidget {
  final String repoPath;

  const DiffView({super.key, required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedFileProvider(repoPath));
    if (selected == null) return const SizedBox.shrink();

    final diff = ref.watch(fileDiffProvider(
        (repo: repoPath, path: selected.path, pane: selected.pane)));
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        _DiffHeader(repoPath: repoPath, selected: selected),
        const Divider(height: 1),
        Expanded(
          child: switch (diff) {
            AsyncData(:final value) => _DiffBody(
                repoPath: repoPath, pane: selected.pane, files: value),
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
    );
  }
}

class _DiffHeader extends ConsumerWidget {
  final String repoPath;
  final SelectedFile selected;

  const _DiffHeader({required this.repoPath, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dir = p.dirname(selected.path);
    final name = p.basename(selected.path);
    final ops = WorkingTreeOps(repoPath, ref);
    final notifier = ref.read(selectedFileProvider(repoPath).notifier);
    final isStaged = selected.pane == DiffPane.staged;
    // For a staged rename, unstaging must reset the old path too; the parsed
    // diff (already loaded for the body) knows the pre-image path.
    final origPath = ref
        .watch(fileDiffProvider(
            (repo: repoPath, path: selected.path, pane: selected.pane)))
        .valueOrNull
        ?.firstOrNull
        ?.oldPath;

    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  if (dir != '.')
                    TextSpan(
                        text: '$dir/',
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  TextSpan(
                      text: name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            _PaneBadge(pane: selected.pane),
            const Spacer(),
            IconButton(
              key: const Key('file-history'),
              tooltip: 'File history',
              icon: const Icon(Icons.history, size: 18),
              onPressed: () =>
                  showFileHistoryDialog(context, repoPath, selected.path),
            ),
            OutlinedButton(
              onPressed: () => _runOp(context, () async {
                if (isStaged) {
                  await ops.unstageFile(selected.path, origPath: origPath);
                  notifier.select(selected.path, DiffPane.unstaged);
                } else {
                  await ops.stageFile(selected.path);
                  notifier.select(selected.path, DiffPane.staged);
                }
              }),
              child: Text(isStaged ? 'Unstage file' : 'Stage file'),
            ),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close, size: 18),
              onPressed: notifier.clear,
            ),
          ],
        ),
      ),
    );
  }
}

class _PaneBadge extends StatelessWidget {
  final DiffPane pane;

  const _PaneBadge({required this.pane});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (pane) {
      DiffPane.unstaged => ('UNSTAGED', Colors.amberAccent),
      DiffPane.staged => ('STAGED', Colors.greenAccent),
      DiffPane.untracked => ('UNTRACKED', Colors.lightBlueAccent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

class _DiffBody extends ConsumerWidget {
  final String repoPath;
  final DiffPane pane;
  final List<FileDiff> files;

  const _DiffBody(
      {required this.repoPath, required this.pane, required this.files});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ops = WorkingTreeOps(repoPath, ref);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        HunksView(
          files: files,
          hunkAction: pane == DiffPane.untracked
              ? null
              : (file, hunk) => pane == DiffPane.staged
                  ? TextButton(
                      onPressed: () =>
                          _runOp(context, () => ops.unstageHunk(file, hunk)),
                      child: const Text('Unstage hunk'),
                    )
                  : TextButton(
                      onPressed: () =>
                          _runOp(context, () => ops.stageHunk(file, hunk)),
                      child: const Text('Stage hunk'),
                    ),
        ),
      ],
    );
  }
}
