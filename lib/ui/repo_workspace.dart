import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../repo/providers.dart';
import 'open_repo.dart';
import 'repo_screen.dart';

/// Tab strip over the open repositories + the active repo screen.
class RepoWorkspace extends ConsumerWidget {
  const RepoWorkspace({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(openReposProvider);
    final active = ref.watch(activeRepoProvider);
    // Keep every open repo's status provider alive: watchers keep running for
    // background tabs, so switching back is instant and already fresh.
    for (final repo in open) {
      ref.watch(repoStatusProvider(repo));
    }
    if (open.isEmpty || active == null) return const SizedBox.shrink();
    return Column(
      children: [
        _TabStrip(open: open, active: active),
        const Divider(height: 1),
        Expanded(child: RepoScreen(repoPath: active, key: ValueKey(active))),
      ],
    );
  }
}

class _TabStrip extends ConsumerWidget {
  final List<String> open;
  final String active;

  const _TabStrip({required this.open, required this.active});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      color: scheme.surfaceContainerHigh,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final repo in open)
                  _RepoTab(path: repo, selected: repo == active),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Open another repository',
            icon: const Icon(Icons.add, size: 18),
            onPressed: () => openRepository(context, ref),
          ),
        ],
      ),
    );
  }
}

class _RepoTab extends ConsumerWidget {
  final String path;
  final bool selected;

  const _RepoTab({required this.path, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => ref.read(activeRepoProvider.notifier).set(path),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? scheme.surface : Colors.transparent,
          border: Border(
            top: BorderSide(
              width: 2,
              color: selected ? scheme.primary : Colors.transparent,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.source_outlined,
                size: 14,
                color: selected ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(p.basename(path),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w400)),
            const SizedBox(width: 6),
            InkWell(
              customBorder: const CircleBorder(),
              onTap: () => ref.read(openReposProvider.notifier).close(path),
              child:
                  Icon(Icons.close, size: 14, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
