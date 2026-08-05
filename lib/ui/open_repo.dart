import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_cli.dart';
import '../repo/providers.dart';
import '../repo/recent_repos.dart';

/// Validates [path] (or shows a directory picker), resolves it to the repo
/// toplevel and opens it as a tab. Returns the toplevel, or null if the
/// picker was cancelled or the directory is not a git repository (an error
/// snackbar is shown for the latter).
Future<String?> openRepository(BuildContext context, WidgetRef ref,
    {String? path}) async {
  path ??= await getDirectoryPath(confirmButtonText: 'Open repository');
  if (path == null) return null;
  final top = await GitCli.discoverToplevel(path);
  if (top == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not a git repository: $path')),
      );
    }
    return null;
  }
  ref.read(openReposProvider.notifier).open(top);
  await ref.read(recentReposProvider.notifier).add(top);
  return top;
}
