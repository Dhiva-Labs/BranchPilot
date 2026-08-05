import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../git/parsers/commit_detail.dart';
import '../../repo/commit_providers.dart';
import '../../repo/graph_providers.dart';
import '../diff/hunks_view.dart';

/// Right-pane detail view for a commit selected in the graph: metadata
/// (subject/body/author/parents) plus a lazily-expandable per-file diff
/// list. Read-only — historical commits don't get edited here.
class CommitDetailPanel extends ConsumerWidget {
  final String repoPath;
  final String hash;

  const CommitDetailPanel(
      {super.key, required this.repoPath, required this.hash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _Header(repoPath: repoPath, hash: hash),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _MetaSection(repoPath: repoPath, hash: hash),
              const SizedBox(height: 18),
              _FilesSection(repoPath: repoPath, hash: hash),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  final String repoPath;
  final String hash;

  const _Header({required this.repoPath, required this.hash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final shortHash = hash.length >= 7 ? hash.substring(0, 7) : hash;
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(shortHash,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary)),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => ref
                  .read(selectedCommitProvider(repoPath).notifier)
                  .select(null),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaSection extends ConsumerWidget {
  final String repoPath;
  final String hash;

  const _MetaSection({required this.repoPath, required this.hash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(commitMetaProvider((repo: repoPath, hash: hash)));
    final scheme = Theme.of(context).colorScheme;
    return switch (meta) {
      AsyncData(:final value) => value == null
          ? Text('Commit not found',
              style: TextStyle(color: scheme.error, fontSize: 12))
          : _MetaBody(meta: value),
      AsyncError(:final error) => Text('$error',
          style: TextStyle(color: scheme.error, fontSize: 12)),
      _ => const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
    };
  }
}

class _MetaBody extends StatelessWidget {
  final CommitMeta meta;

  const _MetaBody({required this.meta});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(meta.subject,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
        if (meta.body.isNotEmpty) ...[
          const SizedBox(height: 8),
          SelectableText(meta.body,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 10),
        Text('${meta.authorName} <${meta.authorEmail}>',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(_absoluteDateTime(meta.authorDate),
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        if (meta.parents.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final parent in meta.parents) _ParentChip(hash: parent),
            ],
          ),
        ],
      ],
    );
  }
}

class _ParentChip extends StatelessWidget {
  final String hash;

  const _ParentChip({required this.hash});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final short = hash.length >= 7 ? hash.substring(0, 7) : hash;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(short,
          style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 10.5,
              color: scheme.onSurfaceVariant)),
    );
  }
}

String _absoluteDateTime(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _FilesSection extends ConsumerWidget {
  final String repoPath;
  final String hash;

  const _FilesSection({required this.repoPath, required this.hash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(commitStatsProvider((repo: repoPath, hash: hash)));
    final scheme = Theme.of(context).colorScheme;
    return switch (stats) {
      AsyncData(:final value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('FILES (${value.length})',
                  style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant)),
            ),
            for (final f in value)
              _FileStatTile(repoPath: repoPath, hash: hash, stat: f),
          ],
        ),
      AsyncError(:final error) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text('$error',
              style: TextStyle(color: scheme.error, fontSize: 12)),
        ),
      _ => const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
    };
  }
}

/// Collapsed→expanded row for one file's stats; lazily loads the file's diff
/// only once the user actually expands it (never up-front for every file in
/// the commit).
class _FileStatTile extends ConsumerStatefulWidget {
  final String repoPath;
  final String hash;
  final FileStat stat;

  const _FileStatTile(
      {required this.repoPath, required this.hash, required this.stat});

  @override
  ConsumerState<_FileStatTile> createState() => _FileStatTileState();
}

class _FileStatTileState extends ConsumerState<_FileStatTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = widget.stat;
    final dir = p.dirname(f.path);
    final name = p.basename(f.path);
    final (badgeChar, badgeColor) = _statusBadge(f);

    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      childrenPadding: EdgeInsets.zero,
      onExpansionChanged: (v) => setState(() => _expanded = v),
      leading: Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(4),
          border:
              Border.all(color: badgeColor.withValues(alpha: 0.55), width: 0.8),
        ),
        child: Text(badgeChar,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: badgeColor)),
      ),
      title: Text.rich(
        TextSpan(children: [
          if (f.oldPath != null)
            TextSpan(
                text: '${f.oldPath} → ',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          if (dir != '.')
            TextSpan(
                text: '$dir/', style: TextStyle(color: scheme.onSurfaceVariant)),
          TextSpan(text: name),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12.5),
      ),
      trailing: f.binary
          ? Text('BIN',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant))
          : Text.rich(TextSpan(children: [
              TextSpan(
                  text: '+${f.added ?? 0} ',
                  style: const TextStyle(
                      color: Colors.greenAccent, fontSize: 11)),
              TextSpan(
                  text: '−${f.deleted ?? 0}',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
            ])),
      children: [
        if (_expanded)
          _ExpandedDiff(repoPath: widget.repoPath, hash: widget.hash, path: f.path),
      ],
    );
  }
}

(String, Color) _statusBadge(FileStat f) {
  if (f.binary) return ('B', Colors.blueGrey);
  if (f.oldPath != null) return ('R', Colors.purpleAccent);
  final added = f.added ?? 0;
  final deleted = f.deleted ?? 0;
  if (deleted == 0 && added > 0) return ('A', Colors.greenAccent);
  if (added == 0 && deleted > 0) return ('D', Colors.redAccent);
  return ('M', Colors.amberAccent);
}

class _ExpandedDiff extends ConsumerWidget {
  final String repoPath;
  final String hash;
  final String path;

  const _ExpandedDiff(
      {required this.repoPath, required this.hash, required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diff = ref.watch(
        commitFileDiffProvider((repo: repoPath, hash: hash, path: path)));
    final scheme = Theme.of(context).colorScheme;
    return switch (diff) {
      AsyncData(:final value) => HunksView(files: value, hunkAction: null),
      AsyncError(:final error) => Padding(
          padding: const EdgeInsets.all(12),
          child: Text('$error',
              style: TextStyle(color: scheme.error, fontSize: 12)),
        ),
      _ => const Padding(
          padding: EdgeInsets.all(12),
          child: Center(
            child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
    };
  }
}
