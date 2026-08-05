import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../git/git_cli.dart';
import '../../git/parsers/unified_diff.dart';
import '../../repo/branch_providers.dart';
import '../../repo/power_providers.dart';
import '../../repo/providers.dart';
import '../../repo/task_providers.dart';
import '../diff/hunks_view.dart';

/// Branches / remotes / stashes panel: the full P4 operations surface
/// (create/checkout/rename/delete/merge branches, checkout remote branches
/// as local, push/apply/pop/drop stashes).
class LeftPanel extends ConsumerWidget {
  final String repoPath;

  const LeftPanel({super.key, required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(branchesProvider(repoPath));
    final stashes = ref.watch(stashesProvider(repoPath));
    final status = ref.watch(repoStatusProvider(repoPath)).valueOrNull;
    final canStash = status != null &&
        (status.staged.isNotEmpty ||
            status.unstaged.isNotEmpty ||
            status.untracked.isNotEmpty);
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10),
        children: [
          _SectionHeader(
            'Branches',
            trailing: IconButton(
              key: const Key('create-branch'),
              tooltip: 'Create branch',
              icon: const Icon(Icons.add, size: 16),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _CreateBranchDialog(repoPath: repoPath),
              ),
            ),
          ),
          ...switch (branches) {
            AsyncData(:final value) => [
                for (final b in value)
                  _BranchTile(repoPath: repoPath, branch: b),
                if (value.isEmpty) const _EmptyNote('no branches yet'),
              ],
            AsyncError() => const [_EmptyNote('could not list branches')],
            _ => const [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              ],
          },
          const SizedBox(height: 18),
          const _SectionHeader('Remotes'),
          _RemotesSection(repoPath: repoPath),
          const SizedBox(height: 18),
          const _SectionHeader('Tags'),
          _TagsSection(repoPath: repoPath),
          const SizedBox(height: 18),
          _SectionHeader(
            'Stashes',
            trailing: IconButton(
              key: const Key('stash-push'),
              tooltip: 'Stash changes',
              icon: const Icon(Icons.add, size: 16),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: canStash
                  ? () => showDialog<void>(
                        context: context,
                        builder: (_) => _StashPushDialog(repoPath: repoPath),
                      )
                  : null,
            ),
          ),
          ...switch (stashes) {
            AsyncData(:final value) => [
                for (final s in value)
                  _StashTile(repoPath: repoPath, stash: s),
                if (value.isEmpty) const _EmptyNote('no stashes'),
              ],
            AsyncError() => const [_EmptyNote('could not list stashes')],
            _ => const [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              ],
          },
          const SizedBox(height: 18),
          _SectionHeader(
            'Worktrees',
            trailing: IconButton(
              key: const Key('worktree-add'),
              tooltip: 'Add worktree',
              icon: const Icon(Icons.add, size: 16),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _AddWorktreeDialog(repoPath: repoPath),
              ),
            ),
          ),
          _WorktreesSection(repoPath: repoPath),
        ],
      ),
    );
  }
}

/// Runs [op], showing any thrown error in a SnackBar instead of letting it
/// escape past a button's onPressed. Same pattern as status_panel.dart /
/// diff_view.dart's `_runOp`.
Future<void> _runOp(BuildContext context, Future<void> Function() op) async {
  try {
    await op();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionHeader(this.title, {this.trailing});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurfaceVariant)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  final String text;

  const _EmptyNote(this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Text(text,
          style: TextStyle(
              fontSize: 11.5,
              fontStyle: FontStyle.italic,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7))),
    );
  }
}

// ---------------------------------------------------------------------------
// Branches
// ---------------------------------------------------------------------------

class _BranchTile extends ConsumerWidget {
  final String repoPath;
  final BranchItem branch;

  const _BranchTile({required this.repoPath, required this.branch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Double-click to checkout',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, ref, details.globalPosition),
        onDoubleTap: branch.isHead
            ? null
            : () => _runOp(context,
                () => BranchOps(repoPath, ref).checkoutBranch(branch.name)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Icon(
                branch.isHead
                    ? Icons.radio_button_checked
                    : Icons.fork_right,
                size: 14,
                color: branch.isHead ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(branch.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight:
                          branch.isHead ? FontWeight.w700 : FontWeight.w400,
                      color: branch.isHead ? scheme.primary : null,
                    )),
              ),
              if (branch.gone)
                const _TinyChip(label: 'gone', color: Colors.redAccent)
              else ...[
                if (branch.ahead > 0)
                  _AbTinyChip(
                      icon: Icons.arrow_upward,
                      count: branch.ahead,
                      color: Colors.greenAccent),
                if (branch.behind > 0)
                  _AbTinyChip(
                      icon: Icons.arrow_downward,
                      count: branch.behind,
                      color: Colors.orangeAccent),
              ],
              const SizedBox(width: 6),
              Text(branch.shortOid,
                  style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showContextMenu(
      BuildContext context, WidgetRef ref, Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(value: 'checkout', child: Text('Checkout')),
        PopupMenuItem(
          value: 'merge',
          enabled: !branch.isHead,
          child: const Text('Merge into current…'),
        ),
        const PopupMenuItem(value: 'rename', child: Text('Rename…')),
        PopupMenuItem(
          value: 'delete',
          enabled: !branch.isHead,
          child: const Text('Delete…'),
        ),
      ],
    );
    if (!context.mounted || selected == null) return;
    switch (selected) {
      case 'checkout':
        await _runOp(context,
            () => BranchOps(repoPath, ref).checkoutBranch(branch.name));
      case 'merge':
        await _confirmMerge(context, ref, repoPath, branch.name);
      case 'rename':
        await showDialog<void>(
          context: context,
          builder: (_) =>
              _RenameBranchDialog(repoPath: repoPath, oldName: branch.name),
        );
      case 'delete':
        await _confirmDeleteBranch(context, ref, repoPath, branch.name);
    }
  }
}

class _TinyChip extends StatelessWidget {
  final String label;
  final Color color;

  const _TinyChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 9.5, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _AbTinyChip extends StatelessWidget {
  final IconData icon;
  final int count;
  final Color color;

  const _AbTinyChip(
      {required this.icon, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          Text('$count',
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

Future<void> _confirmMerge(
    BuildContext context, WidgetRef ref, String repoPath, String name) async {
  final current =
      ref.read(repoStatusProvider(repoPath)).valueOrNull?.branch.head;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Merge ‘$name’ into ${current ?? 'current branch'}?'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Merge')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    final result = await BranchOps(repoPath, ref).mergeBranch(name);
    if (result.exitCode != 0 && context.mounted) {
      final hasConflicts =
          ref.read(repoStatusProvider(repoPath)).valueOrNull?.hasConflicts ??
              false;
      final message = hasConflicts
          ? 'Merge has conflicts — resolve them in the right panel'
          : (result.stderr.trim().isEmpty ? 'Merge failed' : result.stderr.trim());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

Future<void> _confirmDeleteBranch(
    BuildContext context, WidgetRef ref, String repoPath, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete branch ‘$name’?'),
      content: const Text('This cannot be undone.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await BranchOps(repoPath, ref).deleteBranch(name);
  } catch (e) {
    if (e is GitException && e.toString().contains('not fully merged')) {
      if (!context.mounted) return;
      final forceConfirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Branch not fully merged'),
          content: Text(
              '‘$name’ has commits that are not merged into the '
              'current branch. Force delete anyway?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Force delete'),
            ),
          ],
        ),
      );
      if (forceConfirmed == true && context.mounted) {
        await _runOp(context,
            () => BranchOps(repoPath, ref).deleteBranch(name, force: true));
      }
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _CreateBranchDialog extends ConsumerStatefulWidget {
  final String repoPath;

  const _CreateBranchDialog({required this.repoPath});

  @override
  ConsumerState<_CreateBranchDialog> createState() =>
      _CreateBranchDialogState();
}

class _CreateBranchDialogState extends ConsumerState<_CreateBranchDialog> {
  final _nameController = TextEditingController();
  bool _checkout = true;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _valid {
    final n = _nameController.text.trim();
    return n.isNotEmpty && !n.contains(' ');
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    final outerContext = context;
    try {
      await BranchOps(widget.repoPath, ref)
          .createBranch(name, checkout: _checkout);
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
      title: const Text('Create branch'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('branch-name-field'),
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Branch name'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_valid) _create();
            },
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: _checkout,
                onChanged: (v) => setState(() => _checkout = v ?? true),
              ),
              const Text('Check out'),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          key: const Key('branch-create-confirm'),
          onPressed: _valid ? _create : null,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _RenameBranchDialog extends ConsumerStatefulWidget {
  final String repoPath;
  final String oldName;

  const _RenameBranchDialog({required this.repoPath, required this.oldName});

  @override
  ConsumerState<_RenameBranchDialog> createState() =>
      _RenameBranchDialogState();
}

class _RenameBranchDialogState extends ConsumerState<_RenameBranchDialog> {
  late final _nameController = TextEditingController(text: widget.oldName);

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _valid {
    final n = _nameController.text.trim();
    return n.isNotEmpty && !n.contains(' ');
  }

  Future<void> _rename() async {
    final newName = _nameController.text.trim();
    final outerContext = context;
    try {
      await BranchOps(widget.repoPath, ref)
          .renameBranch(widget.oldName, newName);
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
      title: const Text('Rename branch'),
      content: TextField(
        controller: _nameController,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'New name'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (_valid) _rename();
        },
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(onPressed: _valid ? _rename : null, child: const Text('Rename')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Remotes
// ---------------------------------------------------------------------------

class _RemotesSection extends ConsumerWidget {
  final String repoPath;

  const _RemotesSection({required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remotes = ref.watch(remotesProvider(repoPath));
    final branches =
        ref.watch(remoteBranchesProvider(repoPath)).valueOrNull ?? const [];
    return switch (remotes) {
      AsyncData(:final value) => value.isEmpty
          ? const _EmptyNote('no remotes')
          : Column(
              children: [
                for (final r in value)
                  _RemoteExpansion(
                    repoPath: repoPath,
                    remote: r,
                    branches: [for (final b in branches) if (b.remote == r) b],
                  ),
              ],
            ),
      AsyncError() => const _EmptyNote('could not list remotes'),
      _ => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: LinearProgressIndicator(minHeight: 2),
        ),
    };
  }
}

class _RemoteExpansion extends StatelessWidget {
  final String repoPath;
  final String remote;
  final List<RemoteBranchItem> branches;

  const _RemoteExpansion(
      {required this.repoPath, required this.remote, required this.branches});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Wrapped in its own transparent Material: ExpansionTile's header is a
    // ListTile, which paints its background/ink splashes on the nearest
    // Material ancestor. Left panels' opaque ColoredBox sits between here
    // and the Scaffold's Material, which would otherwise hide those effects
    // (a Flutter framework debug assertion catches exactly this).
    return Material(
      type: MaterialType.transparency,
      child: ExpansionTile(
        dense: true,
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: EdgeInsets.zero,
        leading: Icon(Icons.cloud_outlined,
            size: 16, color: scheme.onSurfaceVariant),
        title: Text(remote,
            style:
                const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        children: [
          if (branches.isEmpty) const _EmptyNote('no branches fetched'),
          for (final b in branches)
            _RemoteBranchTile(repoPath: repoPath, branch: b),
        ],
      ),
    );
  }
}

class _RemoteBranchTile extends ConsumerWidget {
  final String repoPath;
  final RemoteBranchItem branch;

  const _RemoteBranchTile({required this.repoPath, required this.branch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 30, right: 6, top: 2, bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(branch.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
          Text(branch.shortOid,
              style: TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant)),
          IconButton(
            tooltip: 'Checkout as local branch',
            icon: const Icon(Icons.download_outlined, size: 14),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => _runOp(
                context,
                () => BranchOps(repoPath, ref)
                    .checkoutRemoteBranch(branch.fullName)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stashes
// ---------------------------------------------------------------------------

class _StashTile extends ConsumerWidget {
  final String repoPath;
  final StashItem stash;

  const _StashTile({required this.repoPath, required this.stash});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined,
              size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(stash.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5)),
          ),
          PopupMenuButton<String>(
            tooltip: 'Stash actions',
            icon: Icon(Icons.more_vert, size: 16, color: scheme.onSurfaceVariant),
            padding: EdgeInsets.zero,
            onSelected: (value) => _onSelected(context, ref, value),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'diff', child: Text('Show diff')),
              PopupMenuItem(value: 'apply', child: Text('Apply')),
              PopupMenuItem(value: 'pop', child: Text('Pop')),
              PopupMenuItem(value: 'drop', child: Text('Drop…')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onSelected(
      BuildContext context, WidgetRef ref, String value) async {
    switch (value) {
      case 'diff':
        await showDialog<void>(
          context: context,
          builder: (_) => _StashDiffDialog(repoPath: repoPath, stash: stash),
        );
      case 'apply':
        await _runOp(
            context, () => StashOps(repoPath, ref).apply(stash.rawRef));
      case 'pop':
        await _runOp(context, () => StashOps(repoPath, ref).pop(stash.rawRef));
      case 'drop':
        await _confirmDropStash(context, ref, repoPath, stash);
    }
  }
}

Future<void> _confirmDropStash(BuildContext context, WidgetRef ref,
    String repoPath, StashItem stash) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Drop stash?'),
      content: Text('‘${stash.message}’ will be permanently deleted.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Drop'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await _runOp(context, () => StashOps(repoPath, ref).drop(stash.rawRef));
  }
}

class _StashPushDialog extends ConsumerStatefulWidget {
  final String repoPath;

  const _StashPushDialog({required this.repoPath});

  @override
  ConsumerState<_StashPushDialog> createState() => _StashPushDialogState();
}

class _StashPushDialogState extends ConsumerState<_StashPushDialog> {
  final _messageController = TextEditingController();
  bool _includeUntracked = true;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _push() async {
    final outerContext = context;
    try {
      await StashOps(widget.repoPath, ref).push(
        message: _messageController.text,
        includeUntracked: _includeUntracked,
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
      title: const Text('Stash changes'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('stash-message-field'),
            controller: _messageController,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Message (optional)'),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: _includeUntracked,
                onChanged: (v) => setState(() => _includeUntracked = v ?? true),
              ),
              const Text('Include untracked'),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        FilledButton(
          key: const Key('stash-confirm'),
          onPressed: _push,
          child: const Text('Stash'),
        ),
      ],
    );
  }
}

class _StashDiffDialog extends ConsumerStatefulWidget {
  final String repoPath;
  final StashItem stash;

  const _StashDiffDialog({required this.repoPath, required this.stash});

  @override
  ConsumerState<_StashDiffDialog> createState() => _StashDiffDialogState();
}

class _StashDiffDialogState extends ConsumerState<_StashDiffDialog> {
  late final Future<List<FileDiff>> _future;

  @override
  void initState() {
    super.initState();
    _future = StashOps(widget.repoPath, ref).show(widget.stash.rawRef);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 700,
        height: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.stash.message,
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
              child: FutureBuilder<List<FileDiff>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('${snapshot.error}',
                            style:
                                TextStyle(color: scheme.error, fontSize: 12)),
                      ),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      HunksView(files: snapshot.data!, hunkAction: null),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

class _TagsSection extends ConsumerStatefulWidget {
  final String repoPath;

  const _TagsSection({required this.repoPath});

  @override
  ConsumerState<_TagsSection> createState() => _TagsSectionState();
}

class _TagsSectionState extends ConsumerState<_TagsSection> {
  static const _collapsedLimit = 8;
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final tags = ref.watch(tagsProvider(widget.repoPath));
    return switch (tags) {
      AsyncData(:final value) =>
        value.isEmpty ? const _EmptyNote('no tags') : _buildList(value),
      AsyncError() => const _EmptyNote('could not list tags'),
      _ => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: LinearProgressIndicator(minHeight: 2),
        ),
    };
  }

  Widget _buildList(List<TagItem> tags) {
    final collapsed = !_showAll && tags.length > _collapsedLimit;
    final visible = collapsed ? tags.take(_collapsedLimit).toList() : tags;
    return Column(
      children: [
        for (final t in visible)
          _TagTile(repoPath: widget.repoPath, tag: t),
        if (collapsed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() => _showAll = true),
              child: Text('show all (${tags.length})',
                  style: const TextStyle(fontSize: 11)),
            ),
          ),
      ],
    );
  }
}

class _TagTile extends ConsumerWidget {
  final String repoPath;
  final TagItem tag;

  const _TagTile({required this.repoPath, required this.tag});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.sell_outlined, size: 14, color: Colors.amberAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(tag.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5)),
          ),
          if (tag.annotated)
            Tooltip(
              message: tag.message ?? '',
              child: const _TinyChip(label: 'A', color: Colors.lightBlueAccent),
            ),
          const SizedBox(width: 6),
          Text(tag.shortOid,
              style: TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant)),
          PopupMenuButton<String>(
            tooltip: 'Tag actions',
            icon:
                Icon(Icons.more_vert, size: 16, color: scheme.onSurfaceVariant),
            padding: EdgeInsets.zero,
            onSelected: (value) => _onSelected(context, ref, value),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'push', child: Text('Push to remote')),
              PopupMenuItem(value: 'delete', child: Text('Delete…')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onSelected(
      BuildContext context, WidgetRef ref, String value) async {
    switch (value) {
      case 'push':
        await _runOp(
            context, () => NetworkOps(repoPath, ref).pushTag(tag.name));
      case 'delete':
        await _confirmDeleteTag(context, ref, repoPath, tag.name);
    }
  }
}

Future<void> _confirmDeleteTag(
    BuildContext context, WidgetRef ref, String repoPath, String name) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete tag ‘$name’?'),
      content: const Text('This cannot be undone.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await _runOp(context, () => PowerOps(repoPath, ref).deleteTag(name));
  }
}

// ---------------------------------------------------------------------------
// Worktrees
// ---------------------------------------------------------------------------

class _WorktreesSection extends ConsumerWidget {
  final String repoPath;

  const _WorktreesSection({required this.repoPath});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worktrees = ref.watch(worktreesProvider(repoPath));
    return switch (worktrees) {
      AsyncData(:final value) => value.isEmpty
          ? const _EmptyNote('no worktrees')
          : Column(
              children: [
                for (final (i, w) in value.indexed)
                  _WorktreeTile(
                    repoPath: repoPath,
                    worktree: w,
                    // The main worktree is always listed first by git; the
                    // path match is a defensive belt-and-braces check.
                    isMain: i == 0 || p.equals(w.path, repoPath),
                  ),
              ],
            ),
      AsyncError() => const _EmptyNote('could not list worktrees'),
      _ => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: LinearProgressIndicator(minHeight: 2),
        ),
    };
  }
}

class _WorktreeTile extends ConsumerWidget {
  final String repoPath;
  final WorktreeInfo worktree;
  final bool isMain;

  const _WorktreeTile(
      {required this.repoPath, required this.worktree, required this.isMain});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final label = worktree.bare
        ? 'bare'
        : (worktree.branch ?? 'detached');
    return InkWell(
      onTap: () => ref.read(openReposProvider.notifier).open(worktree.path),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(isMain ? Icons.home_outlined : Icons.folder_outlined,
                size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: p.basename(worktree.path),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(
                      text: '  $label',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            if (worktree.locked)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.lock_outline,
                    size: 13, color: scheme.onSurfaceVariant),
              ),
            if (!isMain)
              PopupMenuButton<String>(
                tooltip: 'Worktree actions',
                icon: Icon(Icons.more_vert,
                    size: 16, color: scheme.onSurfaceVariant),
                padding: EdgeInsets.zero,
                onSelected: (value) {
                  if (value == 'remove') {
                    _confirmRemoveWorktree(
                        context, ref, repoPath, worktree.path);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'remove', child: Text('Remove…')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _confirmRemoveWorktree(
    BuildContext context, WidgetRef ref, String repoPath, String path) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Remove worktree ‘${p.basename(path)}’?'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await PowerOps(repoPath, ref).removeWorktree(path);
  } catch (e) {
    if (e is GitException &&
        e.toString().contains('contains modified or untracked files')) {
      if (!context.mounted) return;
      final forceConfirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Worktree has changes'),
          content: const Text('Force remove?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Force remove'),
            ),
          ],
        ),
      );
      if (forceConfirmed == true && context.mounted) {
        await _runOp(context,
            () => PowerOps(repoPath, ref).removeWorktree(path, force: true));
      }
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _AddWorktreeDialog extends ConsumerStatefulWidget {
  final String repoPath;

  const _AddWorktreeDialog({required this.repoPath});

  @override
  ConsumerState<_AddWorktreeDialog> createState() =>
      _AddWorktreeDialogState();
}

class _AddWorktreeDialogState extends ConsumerState<_AddWorktreeDialog> {
  final _pathController = TextEditingController();
  final _branchController = TextEditingController();
  String? _existingBranch;

  @override
  void dispose() {
    _pathController.dispose();
    _branchController.dispose();
    super.dispose();
  }

  bool get _newBranchMode => _branchController.text.trim().isNotEmpty;

  bool get _valid {
    final path = _pathController.text.trim();
    if (path.isEmpty || !p.isAbsolute(path)) return false;
    return _newBranchMode || _existingBranch != null;
  }

  Future<void> _create() async {
    final path = _pathController.text.trim();
    final outerContext = context;
    try {
      if (_newBranchMode) {
        await PowerOps(widget.repoPath, ref)
            .addWorktree(path, newBranch: _branchController.text.trim());
      } else {
        await PowerOps(widget.repoPath, ref)
            .addWorktree(path, checkoutExisting: _existingBranch);
      }
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
    final branches =
        ref.watch(branchesProvider(widget.repoPath)).valueOrNull ?? const [];
    return AlertDialog(
      title: const Text('Add worktree'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('worktree-path-field'),
              controller: _pathController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '/path/to/new-worktree',
                helperText: 'Absolute path for the new worktree',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('worktree-branch-field'),
              controller: _branchController,
              decoration: const InputDecoration(
                hintText: 'New branch name',
                helperText:
                    'New branch to create (leave empty to pick existing)',
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (!_newBranchMode) ...[
              const SizedBox(height: 10),
              DropdownButton<String>(
                key: const Key('worktree-existing-dropdown'),
                isExpanded: true,
                hint: const Text('Existing branch'),
                value: _existingBranch,
                items: [
                  for (final b in branches)
                    DropdownMenuItem(value: b.name, child: Text(b.name)),
                ],
                onChanged: (v) => setState(() => _existingBranch = v),
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
          key: const Key('worktree-create-confirm'),
          onPressed: _valid ? _create : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
