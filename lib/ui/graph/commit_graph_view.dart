import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../git/parsers/lane_assignment.dart';
import '../../git/parsers/log_parser.dart';
import '../../repo/branch_providers.dart';
import '../../repo/graph_providers.dart';
import '../../repo/power_providers.dart';
import '../../repo/providers.dart';
import '../dialogs/mainline_picker_dialog.dart';
import '../dialogs/reset_dialog.dart';
import '../rebase/rebase_editor.dart';

const double kGraphRowHeight = 30;
const double kLaneWidth = 14;

const List<Color> _laneColors = [
  Color(0xFF4C8DFF),
  Color(0xFF3DDC97),
  Color(0xFFFFB74D),
  Color(0xFFBA68C8),
  Color(0xFF4DD0E1),
  Color(0xFFF06292),
  Color(0xFFAED581),
  Color(0xFFFF8A65),
  Color(0xFF9575CD),
  Color(0xFF90A4AE),
];

Color laneColor(int lane) => _laneColors[lane % _laneColors.length];

/// Provider-wired commit graph for [repoPath].
class CommitGraphView extends ConsumerWidget {
  final String repoPath;

  const CommitGraphView({super.key, required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final graph = ref.watch(commitGraphProvider(repoPath));
    final selected = ref.watch(selectedCommitProvider(repoPath));
    final scheme = Theme.of(context).colorScheme;
    return switch (graph) {
      AsyncData(:final value) => value.rows.isEmpty
          ? Center(
              child: Text('No commits yet',
                  style: TextStyle(color: scheme.onSurfaceVariant)))
          : GraphList(
              rows: value.rows,
              hasMore: value.hasMore,
              loadingMore: value.loadingMore,
              onLoadMore: () =>
                  ref.read(commitGraphProvider(repoPath).notifier).loadMore(),
              selectedHash: selected,
              onSelect: (hash) => ref
                  .read(selectedCommitProvider(repoPath).notifier)
                  .select(hash),
              repoPath: repoPath,
            ),
      AsyncError(:final error) => Center(
          child: Text('$error',
              style: TextStyle(color: scheme.error, fontSize: 12))),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// Pure presentational graph list — also used directly by tests.
class GraphList extends StatelessWidget {
  final List<GraphRow> rows;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback? onLoadMore;
  final String? selectedHash;
  final ValueChanged<String?>? onSelect;

  /// Enables the right-click context menu (interactive rebase / copy hash)
  /// when non-null. Optional — and defaulting to null — so the visual-dump
  /// and perf tests that construct [GraphList] directly (with no
  /// [ProviderScope] in their widget tree) keep compiling and passing
  /// unmodified: leaving it null skips wiring up any Riverpod-aware widget
  /// at all for those rows.
  final String? repoPath;

  const GraphList({
    super.key,
    required this.rows,
    this.hasMore = false,
    this.loadingMore = false,
    this.onLoadMore,
    this.selectedHash,
    this.onSelect,
    this.repoPath,
  });

  @override
  Widget build(BuildContext context) {
    var maxLanes = 1;
    for (final r in rows) {
      if (r.laneCount > maxLanes) maxLanes = r.laneCount;
    }
    final laneArea =
        8 + kLaneWidth * math.min(maxLanes, 12).toDouble();
    return ListView.builder(
      itemExtent: kGraphRowHeight,
      itemCount: rows.length + (hasMore || loadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= rows.length) {
          if (!loadingMore && onLoadMore != null) {
            Future.microtask(onLoadMore!);
          }
          return const Center(
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final row = rows[i];
        return GraphRowTile(
          row: row,
          laneArea: laneArea,
          selected: row.commit.hash == selectedHash,
          onTap: onSelect == null
              ? null
              : () => onSelect!(
                  row.commit.hash == selectedHash ? null : row.commit.hash),
          repoPath: repoPath,
        );
      },
    );
  }
}

class GraphRowTile extends StatelessWidget {
  final GraphRow row;
  final double laneArea;
  final bool selected;
  final VoidCallback? onTap;

  /// Enables the right-click context menu when non-null (see [GraphList]'s
  /// doc comment on the same field for why this stays nullable).
  final String? repoPath;

  const GraphRowTile({
    super.key,
    required this.row,
    required this.laneArea,
    this.selected = false,
    this.onTap,
    this.repoPath,
  });

  @override
  Widget build(BuildContext context) {
    final tile = _buildTile(context);
    final path = repoPath;
    if (path == null) return tile;
    // Only construct the Consumer (and thus touch Riverpod at all) when a
    // repoPath was actually supplied — see the field doc comment.
    return Consumer(
      builder: (context, ref, child) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) =>
            _showRowContextMenu(context, ref, details.globalPosition, path, row),
        child: child,
      ),
      child: tile,
    );
  }

  Widget _buildTile(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final commit = row.commit;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected
            ? scheme.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        child: Row(
          children: [
            SizedBox(
              width: laneArea,
              height: kGraphRowHeight,
              child: CustomPaint(painter: _GraphRowPainter(row)),
            ),
            const SizedBox(width: 4),
            for (final r in commit.refs.take(3)) ...[
              _RefChip(refName: r),
              const SizedBox(width: 4),
            ],
            if (commit.refs.length > 3) ...[
              _OverflowChip(count: commit.refs.length - 3),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(
                commit.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: selected ? scheme.onSurface : null,
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 110,
              child: Text(
                commit.authorName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 52,
              child: Text(
                _shortDate(commit.authorDate),
                textAlign: TextAlign.right,
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

class _RefChip extends StatelessWidget {
  final RefName refName;

  const _RefChip({required this.refName});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (refName.kind) {
      RefKind.head => (scheme.primary, Icons.gps_fixed),
      RefKind.localBranch => (const Color(0xFF3DDC97), Icons.fork_right),
      RefKind.remoteBranch => (const Color(0xFF9E9EC8), Icons.cloud_outlined),
      RefKind.tag => (const Color(0xFFFFB74D), Icons.sell_outlined),
      RefKind.other => (scheme.onSurfaceVariant, Icons.label_outline),
    };
    final highlight = refName.isCurrent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: highlight ? 0.28 : 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: color.withValues(alpha: highlight ? 0.9 : 0.45),
            width: highlight ? 1.2 : 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              refName.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
                  color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverflowChip extends StatelessWidget {
  final int count;

  const _OverflowChip({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('+$count',
          style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
    );
  }
}

class _GraphRowPainter extends CustomPainter {
  final GraphRow row;

  _GraphRowPainter(this.row);

  double _x(int lane) => kLaneWidth / 2 + lane * kLaneWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final mid = h / 2;
    final cx = _x(row.lane);

    Paint stroke(int lane) => Paint()
      ..color = laneColor(lane)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    // Straight pass-through lanes.
    for (final j in row.continuing) {
      canvas.drawLine(Offset(_x(j), 0), Offset(_x(j), h), stroke(j));
    }

    // Edges from children above converging into the node.
    for (final j in row.mergesIn) {
      if (j == row.lane) {
        canvas.drawLine(Offset(cx, 0), Offset(cx, mid), stroke(j));
      } else {
        final path = Path()
          ..moveTo(_x(j), 0)
          ..quadraticBezierTo(_x(j), mid, cx, mid);
        canvas.drawPath(path, stroke(j));
      }
    }

    // Edges to parents leaving the node downward.
    for (final j in row.forksOut) {
      if (j == row.lane) {
        canvas.drawLine(Offset(cx, mid), Offset(cx, h), stroke(j));
      } else {
        final path = Path()
          ..moveTo(cx, mid)
          ..quadraticBezierTo(_x(j), mid, _x(j), h);
        canvas.drawPath(path, stroke(j));
      }
    }

    // The node bullet: filled dot, hollow ring for merge commits.
    final nodePaint = Paint()..color = laneColor(row.lane);
    if (row.commit.isMerge) {
      nodePaint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(Offset(cx, mid), 3.2, nodePaint);
    } else {
      canvas.drawCircle(Offset(cx, mid), 3.6, nodePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GraphRowPainter oldDelegate) =>
      oldDelegate.row != row;
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Right-click menu for a graph row: interactive rebase onto this commit,
/// copy its full hash, cherry-pick/revert it, tag it, or reset the current
/// branch to it. Same `showMenu` positioning pattern as left_panel.dart's
/// `_BranchTile._showContextMenu`.
Future<void> _showRowContextMenu(BuildContext context, WidgetRef ref,
    Offset globalPosition, String repoPath, GraphRow row) async {
  final snapshot = ref.read(repoStatusProvider(repoPath)).valueOrNull;
  // Default to disabled while the snapshot hasn't loaded yet, rather than
  // momentarily allowing a rebase target we can't yet validate against HEAD.
  final disableRebase = snapshot == null ||
      snapshot.branch.detached ||
      row.commit.hash == snapshot.branch.oid;
  final branchName = snapshot?.branch.head;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final selected = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: [
      PopupMenuItem(
        value: 'rebase',
        enabled: !disableRebase,
        child: const Text('Interactive rebase onto this commit…'),
      ),
      const PopupMenuItem(value: 'copy-hash', child: Text('Copy hash')),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'cherry-pick',
        child: Text(row.commit.isMerge
            ? 'Cherry-pick this merge commit…'
            : 'Cherry-pick this commit'),
      ),
      PopupMenuItem(
        value: 'revert',
        child: Text(row.commit.isMerge
            ? 'Revert this merge commit…'
            : 'Revert this commit'),
      ),
      const PopupMenuItem(value: 'create-tag', child: Text('Create tag here…')),
      PopupMenuItem(
        value: 'reset',
        enabled: branchName != null,
        child: Text('Reset ${branchName ?? 'branch'} to here…'),
      ),
    ],
  );
  if (!context.mounted || selected == null) return;
  switch (selected) {
    case 'rebase':
      await showRebaseEditor(
        context,
        ref,
        repoPath: repoPath,
        baseHash: row.commit.hash,
        baseShortLabel: row.commit.shortHash,
      );
    case 'copy-hash':
      await Clipboard.setData(ClipboardData(text: row.commit.hash));
    case 'cherry-pick':
      await _runCherryPickOrRevert(context, ref, repoPath, row.commit,
          isRevert: false);
    case 'revert':
      await _runCherryPickOrRevert(context, ref, repoPath, row.commit,
          isRevert: true);
    case 'create-tag':
      await showDialog<void>(
        context: context,
        builder: (_) =>
            _CreateTagDialog(repoPath: repoPath, onCommit: row.commit.hash),
      );
    case 'reset':
      if (branchName != null) {
        await showResetDialog(
          context,
          ref,
          repoPath: repoPath,
          hash: row.commit.hash,
          branchName: branchName,
        );
      }
  }
}

/// Runs a cherry-pick or revert of [commit] from the graph's context menu.
/// A merge commit doesn't carry an implicit mainline, so [showMainlinePicker]
/// asks first; cancelling it (returns null) aborts the whole action with no
/// git command run and no SnackBar shown. [PowerOps.cherryPick]/
/// [PowerOps.revert] use `check: false` internally, so a conflict surfaces
/// as a non-zero exit rather than a thrown exception — matched against the
/// actual op state (rather than just "some file is conflicted") so an
/// unrelated pre-existing conflict can't be mistaken for this operation's
/// own outcome.
Future<void> _runCherryPickOrRevert(BuildContext context, WidgetRef ref,
    String repoPath, CommitRecord commit,
    {required bool isRevert}) async {
  final label = isRevert ? 'Revert' : 'Cherry-pick';
  try {
    int? mainline;
    if (commit.isMerge) {
      mainline = await showMainlinePicker(
        context,
        ref,
        repoPath: repoPath,
        parentHashes: commit.parents,
        operationLabel: label,
      );
      if (mainline == null || !context.mounted) return;
    }
    final ops = PowerOps(repoPath, ref);
    final result = isRevert
        ? await ops.revert(commit.hash, mainline: mainline)
        : await ops.cherryPick(commit.hash, mainline: mainline);
    if (result.exitCode == 0 || !context.mounted) return;
    final opState = await ref.read(repoOpStateProvider(repoPath).future);
    if (!context.mounted) return;
    final expected =
        isRevert ? RepoOpState.reverting : RepoOpState.cherryPicking;
    final message = opState == expected
        ? '$label has conflicts — resolve in the right panel'
        : (result.stderr.trim().isEmpty
            ? '$label failed'
            : result.stderr.trim());
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// The graph context menu's tag-creation dialog. Lightweight when the
/// message field is left empty, annotated otherwise — see
/// [PowerOps.createTag].
class _CreateTagDialog extends ConsumerStatefulWidget {
  final String repoPath;
  final String onCommit;

  const _CreateTagDialog({required this.repoPath, required this.onCommit});

  @override
  ConsumerState<_CreateTagDialog> createState() => _CreateTagDialogState();
}

class _CreateTagDialogState extends ConsumerState<_CreateTagDialog> {
  final _nameController = TextEditingController();
  final _messageController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  bool get _valid {
    final n = _nameController.text.trim();
    return n.isNotEmpty && !n.contains(' ');
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    final message = _messageController.text;
    final outerContext = context;
    try {
      await PowerOps(widget.repoPath, ref).createTag(
        name,
        onCommit: widget.onCommit,
        message: message.isEmpty ? null : message,
      );
      if (outerContext.mounted) Navigator.of(outerContext).pop();
    } catch (e) {
      if (outerContext.mounted) {
        ScaffoldMessenger.of(outerContext)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create tag'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('tag-name-field'),
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Tag name'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_valid) _create();
            },
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('tag-message-field'),
            controller: _messageController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'Message (optional)',
              helperText: 'Leave empty for a lightweight tag',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          key: const Key('tag-create-confirm'),
          onPressed: _valid ? _create : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

String _shortDate(DateTime d) {
  final now = DateTime.now();
  final diff = now.difference(d);
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (now.year == d.year) return '${d.day} ${_months[d.month - 1]}';
  return '${_months[d.month - 1]} ${d.year}';
}
