import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../git/parsers/commit_detail.dart';
import '../../git/parsers/porcelain_status.dart';
import '../../repo/branch_providers.dart';
import '../../repo/commit_providers.dart';
import '../../repo/diff_providers.dart';
import '../../repo/power_providers.dart';
import '../../repo/providers.dart';
import '../../repo/rebase_providers.dart';

/// Working-tree panel: conflicted / staged / unstaged / untracked files.
/// Clicking a row opens its diff in the center pane; the per-row and
/// per-group buttons stage/unstage without needing the diff open at all.
class StatusPanel extends ConsumerWidget {
  final String repoPath;

  const StatusPanel({super.key, required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(repoStatusProvider(repoPath));
    final opState =
        ref.watch(repoOpStateProvider(repoPath)).valueOrNull ?? RepoOpState.none;
    final scheme = Theme.of(context).colorScheme;
    final snapshot = status.valueOrNull;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          if (opState != RepoOpState.none)
            _OpStateBanner(
                repoPath: repoPath, opState: opState, snapshot: snapshot),
          Expanded(
            child: switch (status) {
              AsyncData(:final value) =>
                _StatusList(repoPath: repoPath, snapshot: value),
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
          // The commit box needs a live snapshot (staged count, whether HEAD
          // is unborn); until the first one lands there's nothing to commit.
          if (snapshot != null) ...[
            const Divider(height: 1),
            _CommitBox(repoPath: repoPath, snapshot: snapshot),
          ],
        ],
      ),
    );
  }
}

/// Banner shown above the sections list while a multi-step operation
/// (merge/rebase/cherry-pick/revert) is in progress. All four get in-app
/// Abort/Continue actions (plus Skip for rebases); cherry-pick and revert
/// share one pair of buttons (Key('seq-abort')/Key('seq-continue')) since
/// they're both single-commit sequencer operations with identical
/// continue/abort semantics.
class _OpStateBanner extends ConsumerWidget {
  final String repoPath;
  final RepoOpState opState;
  final StatusSnapshot? snapshot;

  const _OpStateBanner(
      {required this.repoPath, required this.opState, required this.snapshot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (title, subtitle) = switch (opState) {
      RepoOpState.merging => (
          'Merge in progress',
          'Resolve conflicts, then continue.'
        ),
      RepoOpState.rebasing => (
          'Rebase in progress',
          'Resolve conflicts, then continue.'
        ),
      RepoOpState.cherryPicking => (
          'Cherry-pick in progress',
          'Resolve conflicts, then continue.'
        ),
      RepoOpState.reverting => (
          'Revert in progress',
          'Resolve conflicts, then continue.'
        ),
      RepoOpState.none => ('', ''),
    };
    // Default to "pending" (disables Continue) while the snapshot hasn't
    // loaded yet, rather than momentarily allowing a commit with unresolved
    // conflicts still in the working tree.
    final conflictsPending = snapshot?.conflicted.isNotEmpty ?? true;
    return Container(
      width: double.infinity,
      color: Colors.deepOrange.withValues(alpha: 0.16),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 18, color: Colors.deepOrangeAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w700)),
                Text(subtitle,
                    style:
                        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (opState == RepoOpState.merging) ...[
            TextButton(
              key: const Key('merge-abort'),
              onPressed: () => _confirmAbortMerge(context, ref, repoPath),
              child: const Text('Abort'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              key: const Key('merge-continue'),
              onPressed: conflictsPending
                  ? null
                  : () => _runOp(
                      context, () => BranchOps(repoPath, ref).continueMerge()),
              child: const Text('Continue'),
            ),
          ] else if (opState == RepoOpState.rebasing) ...[
            TextButton(
              key: const Key('rebase-abort'),
              onPressed: () => _confirmAbortRebase(context, ref, repoPath),
              child: const Text('Abort'),
            ),
            const SizedBox(width: 4),
            TextButton(
              key: const Key('rebase-skip'),
              onPressed: () => _confirmSkipCommit(context, ref, repoPath),
              child: const Text('Skip commit'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              key: const Key('rebase-continue'),
              onPressed: conflictsPending
                  ? null
                  : () => _continueRebase(context, ref, repoPath),
              child: const Text('Continue'),
            ),
          ] else if (opState == RepoOpState.cherryPicking ||
              opState == RepoOpState.reverting) ...[
            TextButton(
              key: const Key('seq-abort'),
              onPressed: () =>
                  _confirmAbortSequencer(context, ref, repoPath, opState),
              child: const Text('Abort'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              key: const Key('seq-continue'),
              onPressed: conflictsPending
                  ? null
                  : () => _continueSequencer(context, ref, repoPath, opState),
              child: const Text('Continue'),
            ),
          ],
        ],
      ),
    );
  }
}

Future<void> _confirmAbortMerge(
    BuildContext context, WidgetRef ref, String repoPath) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Abort merge?'),
      content: const Text(
          'The working tree will be restored to its state before the merge.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Abort'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await _runOp(context, () => BranchOps(repoPath, ref).abortMerge());
  }
}

Future<void> _confirmAbortRebase(
    BuildContext context, WidgetRef ref, String repoPath) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Abort rebase?'),
      content: const Text(
          'The branch will be restored to its state before the rebase.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Abort'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await _runOp(context, () => RebaseOps(repoPath, ref).abort());
  }
}

Future<void> _confirmSkipCommit(
    BuildContext context, WidgetRef ref, String repoPath) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Skip the current commit?'),
      content: const Text('Its changes are discarded.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Skip'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final result = await RebaseOps(repoPath, ref).skipCommit();
  if (!context.mounted || result.exitCode == 0) return;
  final opState = await ref.read(repoOpStateProvider(repoPath).future);
  if (!context.mounted) return;
  final message = opState == RepoOpState.rebasing
      ? 'Still conflicted — resolve remaining files'
      : (result.stderr.trim().isEmpty ? 'Skip failed' : result.stderr.trim());
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Concludes an in-progress rebase step. Mirrors the exit/op-state
/// disambiguation in showRebaseEditor's post-Start handling: a nonzero exit
/// with the op state still `rebasing` is a fresh conflict pause, not a
/// failure.
Future<void> _continueRebase(
    BuildContext context, WidgetRef ref, String repoPath) async {
  final result = await RebaseOps(repoPath, ref).continueRebase();
  if (!context.mounted) return;
  final opState = await ref.read(repoOpStateProvider(repoPath).future);
  if (!context.mounted) return;
  if (result.exitCode == 0) {
    if (opState != RepoOpState.rebasing) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Rebase complete')));
    }
    return;
  }
  final message = opState == RepoOpState.rebasing
      ? 'Paused again — more conflicts to resolve'
      : (result.stderr.trim().isEmpty ? 'Rebase failed' : result.stderr.trim());
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<void> _confirmAbortSequencer(BuildContext context, WidgetRef ref,
    String repoPath, RepoOpState opState) async {
  final label =
      opState == RepoOpState.cherryPicking ? 'cherry-pick' : 'revert';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Abort the $label?'),
      content: Text(
          'The working tree will be restored to its state before the $label.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Abort'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await _runOp(
        context, () => PowerOps(repoPath, ref).abortSequencer(opState));
  }
}

/// Concludes an in-progress cherry-pick or revert. Mirrors
/// [_continueRebase]'s exit/op-state disambiguation: a nonzero exit with the
/// op state unchanged is a fresh conflict pause (more files to resolve), not
/// a failure.
Future<void> _continueSequencer(BuildContext context, WidgetRef ref,
    String repoPath, RepoOpState opState) async {
  final label = opState == RepoOpState.cherryPicking ? 'Cherry-pick' : 'Revert';
  final result = await PowerOps(repoPath, ref).continueSequencer(opState);
  if (!context.mounted) return;
  final newOpState = await ref.read(repoOpStateProvider(repoPath).future);
  if (!context.mounted) return;
  if (result.exitCode == 0) {
    if (newOpState != opState) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$label complete')));
    }
    return;
  }
  final message = newOpState == opState
      ? 'Still conflicted'
      : (result.stderr.trim().isEmpty ? '$label failed' : result.stderr.trim());
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Runs [op], showing any thrown error in a SnackBar instead of letting it
/// escape past a button's onPressed.
Future<void> _runOp(BuildContext context, Future<void> Function() op) async {
  try {
    await op();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _StatusList extends StatelessWidget {
  final String repoPath;
  final StatusSnapshot snapshot;

  const _StatusList({required this.repoPath, required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final conflicted = snapshot.conflicted;
    final staged = snapshot.staged;
    final unstaged = snapshot.unstaged;
    final untracked = snapshot.untracked;
    if (conflicted.isEmpty &&
        staged.isEmpty &&
        unstaged.isEmpty &&
        untracked.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 40, color: Colors.greenAccent.withValues(alpha: 0.7)),
            const SizedBox(height: 8),
            const Text('Working tree clean'),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 10),
      children: [
        if (conflicted.isNotEmpty) ...[
          _GroupHeader(
              repoPath: repoPath,
              title: 'Conflicted',
              count: conflicted.length,
              accent: Colors.deepOrangeAccent,
              pane: null),
          for (final e in conflicted)
            _FileRow(
                repoPath: repoPath,
                entry: e,
                showWorktreeState: true,
                pane: null),
          const SizedBox(height: 14),
        ],
        if (staged.isNotEmpty) ...[
          _GroupHeader(
              repoPath: repoPath,
              title: 'Staged',
              count: staged.length,
              accent: Colors.greenAccent,
              pane: DiffPane.staged),
          for (final e in staged)
            _FileRow(
                repoPath: repoPath,
                entry: e,
                showWorktreeState: false,
                pane: DiffPane.staged),
          const SizedBox(height: 14),
        ],
        if (unstaged.isNotEmpty) ...[
          _GroupHeader(
              repoPath: repoPath,
              title: 'Unstaged',
              count: unstaged.length,
              accent: Colors.amberAccent,
              pane: DiffPane.unstaged),
          for (final e in unstaged)
            _FileRow(
                repoPath: repoPath,
                entry: e,
                showWorktreeState: true,
                pane: DiffPane.unstaged),
          const SizedBox(height: 14),
        ],
        if (untracked.isNotEmpty) ...[
          _GroupHeader(
              repoPath: repoPath,
              title: 'Untracked',
              count: untracked.length,
              accent: Colors.lightBlueAccent,
              pane: DiffPane.untracked),
          for (final e in untracked)
            _FileRow(
                repoPath: repoPath,
                entry: e,
                showWorktreeState: true,
                pane: DiffPane.untracked),
        ],
      ],
    );
  }
}

class _GroupHeader extends ConsumerWidget {
  final String repoPath;
  final String title;
  final int count;
  final Color accent;

  /// Section this header belongs to; null for Conflicted, which has no bulk
  /// stage/unstage action — conflicts are resolved per-file (Take
  /// ours/theirs/Mark resolved on each row), not staged/unstaged in bulk.
  final DiffPane? pane;

  const _GroupHeader({
    required this.repoPath,
    required this.title,
    required this.count,
    required this.accent,
    required this.pane,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final trailingLabel = switch (pane) {
      DiffPane.staged => 'Unstage all',
      DiffPane.unstaged => 'Stage all',
      DiffPane.untracked => 'Stage all',
      null => null,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(title.toUpperCase(),
              style: TextStyle(
                  fontSize: 10.5,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant)),
          const SizedBox(width: 6),
          Text('$count',
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: accent)),
          const Spacer(),
          if (trailingLabel != null)
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () {
                final ops = WorkingTreeOps(repoPath, ref);
                _runOp(
                    context,
                    () => pane == DiffPane.staged
                        ? ops.unstageAll()
                        : ops.stageAll());
              },
              child: Text(trailingLabel, style: const TextStyle(fontSize: 10.5)),
            ),
        ],
      ),
    );
  }
}

class _FileRow extends ConsumerWidget {
  final String repoPath;
  final StatusEntry entry;

  /// Whether the badge reflects the worktree (Y) or index (X) side.
  final bool showWorktreeState;

  /// Section this row belongs to; null for Conflicted rows — they're not
  /// selectable for diffing (no center-pane diff view for a conflict), so
  /// they get the resolve actions ([_ConflictActions]) instead of a
  /// stage/unstage button.
  final DiffPane? pane;

  const _FileRow({
    required this.repoPath,
    required this.entry,
    required this.showWorktreeState,
    required this.pane,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final state = entry.unmerged
        ? FileState.unmerged
        : entry.untracked
            ? FileState.untracked
            : showWorktreeState
                ? entry.worktreeState
                : entry.indexState;
    final (char, color) = _badge(state);
    final dir = p.dirname(entry.path);
    final name = p.basename(entry.path);

    // A partially-staged ("MM") file appears in both the Staged and
    // Unstaged lists as two separate rows; comparing the pane alongside the
    // path is what keeps only the row for the clicked section highlighted.
    final selected = ref.watch(selectedFileProvider(repoPath));
    final isSelected =
        pane != null && selected?.pane == pane && selected?.path == entry.path;

    return InkWell(
      onTap: pane == null
          ? null
          : () => ref
              .read(selectedFileProvider(repoPath).notifier)
              .select(entry.path, pane!),
      child: Container(
        color:
            isSelected ? scheme.primary.withValues(alpha: 0.14) : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: Row(
            children: [
              Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: color.withValues(alpha: 0.55), width: 0.8),
                ),
                child: Text(char,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: color)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (entry.origPath != null)
                        TextSpan(
                            text: '${entry.origPath} → ',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      if (dir != '.')
                        TextSpan(
                            text: '$dir/',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      TextSpan(text: name),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              if (entry.unmerged)
                _ConflictActions(repoPath: repoPath, path: entry.path)
              else if (pane == DiffPane.staged)
                _RowIconButton(
                  icon: Icons.remove,
                  tooltip: 'Unstage',
                  onPressed: () => _runOp(context,
                      () => WorkingTreeOps(repoPath, ref)
                          .unstageFile(entry.path, origPath: entry.origPath)),
                )
              else if (pane == DiffPane.unstaged || pane == DiffPane.untracked)
                _RowIconButton(
                  icon: Icons.add,
                  tooltip: 'Stage',
                  onPressed: () => _runOp(context,
                      () => WorkingTreeOps(repoPath, ref).stageFile(entry.path)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Trailing actions for a conflicted row: resolve to one side, or mark
/// resolved as-is (e.g. after hand-editing the file to remove the conflict
/// markers).
class _ConflictActions extends ConsumerWidget {
  final String repoPath;
  final String path;

  const _ConflictActions({required this.repoPath, required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Take ours',
          icon: const Icon(Icons.flip_to_back, size: 15),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
          onPressed: () => _runOp(
              context, () => BranchOps(repoPath, ref).resolveOurs(path)),
        ),
        IconButton(
          tooltip: 'Take theirs',
          icon: const Icon(Icons.flip_to_front, size: 15),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
          onPressed: () => _runOp(
              context, () => BranchOps(repoPath, ref).resolveTheirs(path)),
        ),
        IconButton(
          key: const Key('mark-resolved'),
          tooltip: 'Mark resolved',
          icon: const Icon(Icons.check, size: 15),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
          onPressed: () => _runOp(
              context, () => BranchOps(repoPath, ref).markResolved(path)),
        ),
      ],
    );
  }
}

class _RowIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _RowIconButton(
      {required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      onPressed: onPressed,
    );
  }
}

(String, Color) _badge(FileState s) => switch (s) {
      FileState.added => ('A', Colors.greenAccent),
      FileState.modified => ('M', Colors.amberAccent),
      FileState.deleted => ('D', Colors.redAccent),
      FileState.renamed => ('R', Colors.purpleAccent),
      FileState.copied => ('C', Colors.purpleAccent),
      FileState.typeChanged => ('T', Colors.tealAccent),
      FileState.unmerged => ('U', Colors.deepOrangeAccent),
      FileState.untracked => ('?', Colors.lightBlueAccent),
      FileState.ignored => ('!', Colors.blueGrey),
      FileState.unmodified => ('·', Colors.grey),
    };

/// Registration point for the commit box's "trySubmit" hook: RepoScreen's
/// Ctrl+Enter shortcut reads this instead of duplicating
/// `_CommitBoxState`'s enablement guard. Null whenever the Commit/Amend
/// button itself would be disabled; otherwise a callback equivalent to
/// tapping it. Set from `_CommitBoxState.build` (recomputed on every
/// keystroke/amend toggle, so the two guards can never drift apart).
///
/// Deliberately NOT cleared from `_CommitBoxState.dispose()`: Riverpod's
/// `ConsumerStatefulElement` has already marked itself disposed by the time
/// a `ConsumerState.dispose()` override runs, so `ref.read(...)` inside
/// `dispose()` throws ("Cannot use ref after the widget was disposed") —
/// empirically confirmed via integration_test/keyboard_shortcuts_test.dart,
/// not just reasoned about. Instead, `_commit` itself guards on `mounted`
/// first, so an already-unmounted box's stale callback (e.g. selecting a
/// historical commit swaps in CommitDetailPanel in its place) is a safe
/// no-op rather than a crash.
class CommitBoxActionNotifier
    extends AutoDisposeFamilyNotifier<VoidCallback?, String> {
  @override
  VoidCallback? build(String arg) => null;

  void set(VoidCallback? action) {
    if (state != action) state = action;
  }
}

final commitBoxActionProvider = NotifierProvider.autoDispose
    .family<CommitBoxActionNotifier, VoidCallback?, String>(
        CommitBoxActionNotifier.new);

/// Bottom-anchored commit editor: subject + optional body, an amend toggle,
/// and a commit button whose label/enablement track the live staged count.
class _CommitBox extends ConsumerStatefulWidget {
  final String repoPath;
  final StatusSnapshot snapshot;

  const _CommitBox({required this.repoPath, required this.snapshot});

  @override
  ConsumerState<_CommitBox> createState() => _CommitBoxState();
}

class _CommitBoxState extends ConsumerState<_CommitBox> {
  final _subjectController = TextEditingController();
  final _bodyController = TextEditingController();
  bool _amend = false;

  @override
  void dispose() {
    _subjectController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _toggleAmend(bool? value) async {
    final v = value ?? false;
    setState(() => _amend = v);
    if (!v) return; // turning off never clears user-entered text
    if (_subjectController.text.isNotEmpty || _bodyController.text.isNotEmpty) {
      return;
    }
    final msg = await CommitOps(widget.repoPath, ref).lastCommitMessage();
    if (!mounted || msg.isEmpty) return;
    final (subject, body) = splitSubjectBody(msg);
    setState(() {
      _subjectController.text = subject;
      _bodyController.text = body;
    });
  }

  /// Guards on [mounted] before touching `context`/`ref` at all: this can be
  /// invoked via [commitBoxActionProvider] from RepoScreen's Ctrl+Enter
  /// shortcut, which may still hold a reference registered before this box
  /// unmounted (see that provider's doc comment for why it isn't cleared on
  /// dispose) — a stale call must be a safe no-op, not a crash.
  Future<void> _commit() async {
    if (!mounted) return;
    await _runOp(context, () async {
      await CommitOps(widget.repoPath, ref).commit(
        subject: _subjectController.text,
        body: _bodyController.text,
        amend: _amend,
      );
      if (!mounted) return;
      setState(() {
        _subjectController.clear();
        _bodyController.clear();
        _amend = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stagedCount = widget.snapshot.staged.length;
    final subjectLen = _subjectController.text.length;
    final canCommit =
        _subjectController.text.trim().isNotEmpty && (stagedCount > 0 || _amend);
    final counterColor = subjectLen > 72
        ? scheme.error
        : subjectLen > 50
            ? Colors.amberAccent
            : scheme.onSurfaceVariant;

    // Publish this build's version of the enablement guard for RepoScreen's
    // Ctrl+Enter shortcut to read. Deferred to after the frame: Riverpod
    // (rightly) disallows modifying a provider's state synchronously from
    // inside another widget's build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(commitBoxActionProvider(widget.repoPath).notifier)
          .set(canCommit ? _commit : null);
    });

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('commit-subject'),
            controller: _subjectController,
            maxLines: 1,
            style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Commit subject',
            ),
            onChanged: (_) => setState(() {}),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 2),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('$subjectLen/72',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: counterColor)),
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('commit-body'),
            controller: _bodyController,
            minLines: 2,
            maxLines: 6,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Description (optional)',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Checkbox(
                key: const Key('amend-toggle'),
                value: _amend,
                onChanged: widget.snapshot.branch.initial ? null : _toggleAmend,
              ),
              const Text('Amend', style: TextStyle(fontSize: 12.5)),
              const Spacer(),
              Tooltip(
                message: 'Commit (Ctrl+Enter)',
                child: FilledButton(
                  key: const Key('commit-button'),
                  onPressed: canCommit ? _commit : null,
                  child: Text(_amend ? 'Amend' : 'Commit ($stagedCount)'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
