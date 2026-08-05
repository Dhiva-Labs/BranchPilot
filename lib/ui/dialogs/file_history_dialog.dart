import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../repo/commit_providers.dart';
import '../../repo/power_providers.dart';
import '../diff/hunks_view.dart';

/// Opens the per-file history dialog for [path] (repo-relative): a
/// `--follow`ed commit list on the left, and the selected commit's diff for
/// that file on the right.
Future<void> showFileHistoryDialog(
  BuildContext context,
  String repoPath,
  String path,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _FileHistoryDialog(repoPath: repoPath, path: path),
  );
}

class _FileHistoryDialog extends ConsumerStatefulWidget {
  final String repoPath;
  final String path;

  const _FileHistoryDialog({required this.repoPath, required this.path});

  @override
  ConsumerState<_FileHistoryDialog> createState() =>
      _FileHistoryDialogState();
}

class _FileHistoryDialogState extends ConsumerState<_FileHistoryDialog> {
  /// Null until the user picks a different entry — defaults to the newest
  /// commit (the list's first entry) once history has loaded.
  String? _selectedHash;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final history = ref.watch(
        fileHistoryProvider((repo: widget.repoPath, path: widget.path)));
    return Dialog(
      child: SizedBox(
        width: 900,
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(p.basename(widget.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
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
              child: switch (history) {
                AsyncData(:final value) => value.isEmpty
                    ? const Center(child: Text('No commits touch this file'))
                    : _HistoryBody(
                        repoPath: widget.repoPath,
                        path: widget.path,
                        entries: value,
                        selectedHash: _selectedHash ?? value.first.hash,
                        onSelect: (hash) =>
                            setState(() => _selectedHash = hash),
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

class _HistoryBody extends StatelessWidget {
  final String repoPath;
  final String path;
  final List<FileHistoryEntry> entries;
  final String selectedHash;
  final ValueChanged<String> onSelect;

  const _HistoryBody({
    required this.repoPath,
    required this.path,
    required this.entries,
    required this.selectedHash,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    for (final e in entries)
                      _HistoryRow(
                        entry: e,
                        selected: e.hash == selectedHash,
                        onTap: () => onSelect(e.hash),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('Follows renames',
                    style: TextStyle(
                        fontSize: 10.5,
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurfaceVariant)),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _CommitDiffPane(
              repoPath: repoPath, hash: selectedHash, path: path),
        ),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final FileHistoryEntry entry;
  final bool selected;
  final VoidCallback onTap;

  const _HistoryRow(
      {required this.entry, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected
            ? scheme.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.subject,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('${entry.authorName} · ${_formatDate(entry.date)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text(entry.shortHash,
                style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _CommitDiffPane extends ConsumerWidget {
  final String repoPath;
  final String hash;
  final String path;

  const _CommitDiffPane(
      {required this.repoPath, required this.hash, required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diff = ref.watch(
        commitFileDiffProvider((repo: repoPath, hash: hash, path: path)));
    final scheme = Theme.of(context).colorScheme;
    return switch (diff) {
      AsyncData(:final value) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [HunksView(files: value, hunkAction: null)],
        ),
      AsyncError(:final error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('$error',
                style: TextStyle(color: scheme.error, fontSize: 12)),
          ),
        ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
