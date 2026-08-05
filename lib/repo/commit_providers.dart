import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_cli.dart';
import '../git/parsers/commit_detail.dart';
import '../git/parsers/unified_diff.dart';
import 'providers.dart';

/// Historical commit metadata for the commit-detail panel. Nothing here
/// re-fetches on status changes — a historical commit's own data never
/// changes once made (amend/rebase produce a *different* hash, which is a
/// different provider instance).
final commitMetaProvider = FutureProvider.autoDispose
    .family<CommitMeta?, ({String repo, String hash})>((ref, arg) async {
  try {
    final r = await GitCli(arg.repo)
        .run(['show', '-s', '--format=$commitMetaFormat', arg.hash]);
    return parseCommitMeta(r.stdout);
  } on GitException {
    return null;
  }
});

/// Per-file added/deleted line counts for one commit.
final commitStatsProvider = FutureProvider.autoDispose
    .family<List<FileStat>, ({String repo, String hash})>((ref, arg) async {
  final r = await GitCli(arg.repo)
      .run(['show', '--numstat', '--format=', '-z', arg.hash]);
  return parseNumstatZ(r.stdout);
});

/// Parsed diff for one file as it changed in one historical commit. No
/// status watch needed — historical commits don't change.
final commitFileDiffProvider = FutureProvider.autoDispose
    .family<List<FileDiff>, ({String repo, String hash, String path})>(
        (ref, arg) async {
  final r = await GitCli(arg.repo).run(
      ['show', '-U3', '--no-color', '--format=', arg.hash, '--', arg.path]);
  return parseUnifiedDiff(r.stdout);
});

/// Commit-creation operations invoked from the commit box: a plain commit or
/// an amend, plus fetching the previous message to prefill the amend editor.
class CommitOps {
  final String repo;
  final WidgetRef ref;

  CommitOps(this.repo, this.ref);

  GitCli get _git => GitCli(repo);

  Future<void> commit({
    required String subject,
    String body = '',
    bool amend = false,
  }) async {
    final message =
        subject + (body.trim().isEmpty ? '' : '\n\n${body.trimRight()}');
    await _git.run(
      ['commit', if (amend) '--amend', '-F', '-'],
      stdin: utf8.encode(message),
    );
    await ref.read(repoStatusProvider(repo).notifier).refresh();
  }

  /// The current HEAD's full commit message, for amend prefill; '' if HEAD
  /// is unborn (nothing to amend yet).
  Future<String> lastCommitMessage() async {
    try {
      final r = await _git.run(['log', '-1', '--pretty=%B']);
      return r.stdout.trimRight();
    } on GitException {
      return '';
    }
  }
}
