import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../repo/recent_repos.dart';
import 'open_repo.dart';

/// Welcome view shown when no repository is open.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent =
        ref.watch(recentReposProvider).valueOrNull ?? const <String>[];
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.account_tree_rounded,
                size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('BranchPilot',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('A git client for Linux',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 24),
            Center(
              child: FilledButton.icon(
                onPressed: () => openRepository(context, ref),
                icon: const Icon(Icons.folder_open),
                label: const Text('Open repository…'),
              ),
            ),
            const SizedBox(height: 28),
            if (recent.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 6),
                child: Text('RECENT',
                    style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.4,
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final path in recent) _RecentTile(path: path),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecentTile extends ConsumerWidget {
  final String path;

  const _RecentTile({required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exists = Directory(path).existsSync();
    return ListTile(
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: Icon(Icons.source_outlined,
          size: 20, color: exists ? null : Theme.of(context).disabledColor),
      title: Text(p.basename(path)),
      subtitle: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
      enabled: exists,
      onTap: () => openRepository(context, ref, path: path),
      trailing: IconButton(
        tooltip: 'Remove from recent',
        icon: const Icon(Icons.close, size: 16),
        onPressed: () => ref.read(recentReposProvider.notifier).remove(path),
      ),
    );
  }
}
