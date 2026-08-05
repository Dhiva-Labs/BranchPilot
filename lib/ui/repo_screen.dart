import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../git/parsers/porcelain_status.dart';
import '../repo/diff_providers.dart';
import '../repo/graph_providers.dart';
import '../repo/providers.dart';
import '../repo/task_providers.dart';
import 'diff/diff_view.dart';
import 'graph/commit_graph_view.dart';
import 'panels/commit_detail_panel.dart';
import 'panels/left_panel.dart';
import 'panels/status_panel.dart';
import 'panels/task_strip.dart';

class RepoScreen extends ConsumerWidget {
  final String repoPath;

  const RepoScreen({super.key, required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(repoStatusProvider(repoPath));
    final selectedCommit = ref.watch(selectedCommitProvider(repoPath));
    // Keeps commitBoxActionProvider's autoDispose family instance alive for
    // as long as this screen is mounted. status_panel.dart's
    // _CommitBoxState registers the actual callback on every build; this
    // just pins the instance so a read from the Ctrl+Enter binding below is
    // never looking at a freshly torn-down (and re-defaulted-to-null)
    // instance.
    ref.watch(commitBoxActionProvider(repoPath));

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        LogicalKeySet(LogicalKeyboardKey.space): () =>
            _handleSpaceShortcut(context, ref, repoPath),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.enter):
            () => _handleCommitShortcut(ref, repoPath),
        LogicalKeySet(LogicalKeyboardKey.f5): () =>
            _handleFetchShortcut(context, ref, repoPath),
      },
      child: FocusScope(
        autofocus: true,
        // A real FocusScope (not just a Focus node) so that when a
        // descendant loses focus without anything else specific claiming it
        // (e.g. tapping away from the commit subject field onto a plain,
        // non-text row), focus falls back to *this* scope rather than
        // unwinding all the way out to the Navigator's own top-level scope —
        // which would sit outside CallbackShortcuts' own Focus node above
        // and silently stop these shortcuts from ever firing again for the
        // rest of the session. autofocus only claims focus once (at first
        // build); it never steals focus back from a TextField the user is
        // actively using.
        child: Column(
          children: [
            _RepoHeader(repoPath: repoPath, status: status),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 260, child: LeftPanel(repoPath: repoPath)),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: ref.watch(selectedFileProvider(repoPath)) !=
                                  null
                              ? DiffView(repoPath: repoPath)
                              : CommitGraphView(repoPath: repoPath),
                        ),
                        TaskStrip(repoPath: repoPath),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: 380,
                    child: selectedCommit != null
                        ? CommitDetailPanel(
                            repoPath: repoPath, hash: selectedCommit)
                        : StatusPanel(repoPath: repoPath),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// True while the currently focused widget lives inside a text-editing
/// field (the commit subject/body, or any other TextField this screen might
/// gain later). Only the Space shortcut needs this guard — Ctrl+Enter is
/// deliberately meant to submit the commit box from *inside* its own fields
/// (that's the entire point of a "quick submit" chord, same as GitHub/Slack
/// comment boxes), and F5 fetching while some unrelated field happens to
/// have focus is harmless.
bool _isTextInputFocused() {
  final focused = FocusManager.instance.primaryFocus;
  final ctx = focused?.context;
  return ctx?.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Space: toggles stage/unstage of whichever file is selected in the diff
/// view. Mirrors the exact per-row/per-header action in
/// status_panel.dart/diff_view.dart — including the origPath lookup a
/// staged rename needs to fully unstage both sides of. No-op if nothing is
/// selected, or if a text field currently has focus (so typing a literal
/// space into the commit box just types a space).
void _handleSpaceShortcut(BuildContext context, WidgetRef ref, String repoPath) {
  if (_isTextInputFocused()) return;
  final sel = ref.read(selectedFileProvider(repoPath));
  if (sel == null) return;
  final ops = WorkingTreeOps(repoPath, ref);
  if (sel.pane == DiffPane.staged) {
    final snapshot = ref.read(repoStatusProvider(repoPath)).valueOrNull;
    final matches = (snapshot?.staged ?? const <StatusEntry>[])
        .where((e) => e.path == sel.path);
    final origPath = matches.isEmpty ? null : matches.first.origPath;
    _runOp(context, () => ops.unstageFile(sel.path, origPath: origPath));
  } else {
    _runOp(context, () => ops.stageFile(sel.path));
  }
}

/// Ctrl+Enter: submits the commit box exactly as its own button would. Reads
/// the callback `_CommitBoxState` (status_panel.dart) registers via
/// [commitBoxActionProvider] — null whenever the button itself would be
/// disabled — so the two guards can never drift apart.
void _handleCommitShortcut(WidgetRef ref, String repoPath) {
  ref.read(commitBoxActionProvider(repoPath))?.call();
}

/// F5: fetch all remotes, mirroring the header Fetch button's own
/// busy-gating so a repeat press while one is already running is a no-op
/// instead of queuing a second fetch.
void _handleFetchShortcut(
    BuildContext context, WidgetRef ref, String repoPath) {
  final tasks = ref.read(tasksProvider(repoPath));
  if (_hasRunningTask(tasks, (l) => l == 'Fetch')) return;
  _runOp(context, () => NetworkOps(repoPath, ref).fetchAll());
}

class _RepoHeader extends ConsumerWidget {
  final String repoPath;
  final AsyncValue<StatusSnapshot> status;

  const _RepoHeader({required this.repoPath, required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final branch = status.valueOrNull?.branch;
    final ahead = branch?.ahead ?? 0;
    final behind = branch?.behind ?? 0;
    final disableRemoteOps = branch == null || branch.detached || branch.initial;
    final tasks = ref.watch(tasksProvider(repoPath));
    final fetchBusy = _hasRunningTask(tasks, (l) => l == 'Fetch');
    final pullBusy = _hasRunningTask(tasks, (l) => l == 'Pull');
    final pushBusy = _hasRunningTask(
        tasks,
        (l) =>
            l == 'Push' || l == 'Push (set upstream)' || l == 'Force push');
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Text(p.basename(repoPath),
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(width: 12),
            if (branch != null) _BranchChip(branch: branch),
            const SizedBox(width: 8),
            if (ahead > 0)
              _AbChip(
                  icon: Icons.arrow_upward,
                  count: ahead,
                  color: Colors.greenAccent),
            if (behind > 0)
              _AbChip(
                  icon: Icons.arrow_downward,
                  count: behind,
                  color: Colors.orangeAccent),
            const Spacer(),
            Flexible(
              child: Text(repoPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const Key('fetch-button'),
              tooltip: 'Fetch all remotes (F5)',
              icon: const Icon(Icons.sync, size: 18),
              onPressed: fetchBusy
                  ? null
                  : () => _runOp(context, () => NetworkOps(repoPath, ref).fetchAll()),
            ),
            IconButton(
              key: const Key('pull-button'),
              tooltip: behind > 0 ? 'Pull (behind $behind)' : 'Pull',
              icon: const Icon(Icons.arrow_downward, size: 18),
              onPressed: (pullBusy || disableRemoteOps)
                  ? null
                  : () => _runOp(context, () => NetworkOps(repoPath, ref).pull()),
            ),
            IconButton(
              key: const Key('push-button'),
              tooltip: ahead > 0 ? 'Push (ahead $ahead)' : 'Push',
              icon: const Icon(Icons.arrow_upward, size: 18),
              onPressed: (pushBusy || disableRemoteOps)
                  ? null
                  : () => _runOp(context, () => NetworkOps(repoPath, ref).push()),
            ),
            PopupMenuButton<String>(
              key: const Key('push-menu'),
              tooltip: 'More push options',
              enabled: !(pushBusy || disableRemoteOps),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.expand_more, size: 14),
              onSelected: (_) {
                final name = branch?.head;
                if (name == null) return;
                _confirmForcePush(context, ref, repoPath, name);
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                    value: 'force', child: Text('Force push (with lease)…')),
              ],
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Refresh everything',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => _refreshEverything(ref, repoPath),
            ),
          ],
        ),
      ),
    );
  }
}

/// Refreshes everything the repo screen shows that can otherwise go stale
/// from a change made *outside* the app — a tag/stash/branch/worktree
/// created from a terminal, or a remote branch discovered by a manual
/// `git fetch` run elsewhere.
///
/// P8 investigation: every provider that lists such data —
/// `branchesProvider`, `tagsProvider`, `stashesProvider`, `worktreesProvider`,
/// `remoteBranchesProvider`, `remotesProvider`, `repoOpStateProvider`, and
/// `fileDiffProvider` — already either `ref.watch`es or `ref.listen`s
/// [repoStatusProvider] (see branch_providers.dart/power_providers.dart/
/// diff_providers.dart), and `commitGraphProvider` reloads itself via its own
/// `ref.listen` on the same provider (graph_providers.dart). Crucially,
/// `RepoStatusNotifier.refresh()` always assigns a brand-new `StatusSnapshot`
/// instance — freshly parsed on every call — and nothing in that class tree
/// (`StatusSnapshot`/`BranchInfo`/`StatusEntry`) overrides `==`, so Riverpod
/// never short-circuits the update as a no-op; every dependent provider
/// above already recomputes from this one call. That means no provider here
/// needed its own explicit `ref.invalidate` — confirmed empirically (not just
/// by this reasoning) in test/git/refresh_everything_test.dart against real
/// git fixtures.
void _refreshEverything(WidgetRef ref, String repoPath) {
  ref.read(repoStatusProvider(repoPath).notifier).refresh();
}

/// True when [tasks] has a still-running entry whose label satisfies
/// [matches] — used to disable the Fetch/Pull/Push controls while their own
/// operation is already in flight.
bool _hasRunningTask(
        List<GitTask> tasks, bool Function(String label) matches) =>
    tasks.any((t) => t.state == GitTaskState.running && matches(t.label));

Future<void> _confirmForcePush(BuildContext context, WidgetRef ref,
    String repoPath, String branchName) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _ForcePushDialog(branchName: branchName),
  );
  if (confirmed == true && context.mounted) {
    _runOp(context, () => NetworkOps(repoPath, ref).push(forceWithLease: true));
  }
}

/// Runs [op], showing any thrown error in a SnackBar instead of letting it
/// escape past a button's onPressed. Same pattern as status_panel.dart /
/// left_panel.dart's `_runOp`. Nonzero git exits are not errors here — those
/// surface through the task strip, which every op keeps updated regardless
/// of outcome; this only catches pre-flight failures thrown before a task
/// even starts (e.g. a detached HEAD, or no remotes configured).
Future<void> _runOp(BuildContext context, Future<void> Function() op) async {
  try {
    await op();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Typed-confirmation dialog for `push --force-with-lease`: the user must
/// type the branch name exactly before the Force push button enables, since
/// this rewrites the remote branch.
class _ForcePushDialog extends StatefulWidget {
  final String branchName;

  const _ForcePushDialog({required this.branchName});

  @override
  State<_ForcePushDialog> createState() => _ForcePushDialogState();
}

class _ForcePushDialogState extends State<_ForcePushDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _confirmed => _controller.text == widget.branchName;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Force push with lease'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('This rewrites the remote branch. Type the branch name '
              'to confirm.'),
          const SizedBox(height: 10),
          TextField(
            key: const Key('force-push-field'),
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(hintText: widget.branchName),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_confirmed) Navigator.of(context).pop(true);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          key: const Key('force-push-confirm'),
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: _confirmed ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Force push'),
        ),
      ],
    );
  }
}

class _BranchChip extends StatelessWidget {
  final BranchInfo branch;

  const _BranchChip({required this.branch});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final oid = branch.oid;
    final label = branch.detached
        ? 'HEAD @ ${oid == null ? '?' : oid.substring(0, 7)}'
        : branch.head!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(branch.detached ? Icons.gps_off : Icons.fork_right,
              size: 14, color: scheme.primary),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary)),
          if (branch.upstream != null) ...[
            const SizedBox(width: 6),
            Text('⇄ ${branch.upstream}',
                style:
                    TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _AbChip extends StatelessWidget {
  final IconData icon;
  final int count;
  final Color color;

  const _AbChip(
      {required this.icon, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          Text('$count',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

