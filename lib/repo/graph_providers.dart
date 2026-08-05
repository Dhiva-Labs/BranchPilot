import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_cli.dart';
import '../git/parsers/lane_assignment.dart';
import '../git/parsers/log_parser.dart';
import 'providers.dart';

class CommitGraph {
  final List<GraphRow> rows;
  final int totalCount;
  final bool loadingMore;

  const CommitGraph({
    required this.rows,
    required this.totalCount,
    this.loadingMore = false,
  });

  bool get hasMore => rows.length < totalCount;

  CommitGraph copyWith({bool? loadingMore}) => CommitGraph(
        rows: rows,
        totalCount: totalCount,
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

/// Paged commit graph for one repository. Reloads (preserving the number of
/// loaded commits) whenever the status snapshot changes — the watcher already
/// debounces, and a 500–2000 commit log run is cheap.
class CommitGraphNotifier
    extends AutoDisposeFamilyAsyncNotifier<CommitGraph, String> {
  static const pageSize = 500;

  List<CommitRecord> _commits = const [];

  @override
  Future<CommitGraph> build(String arg) async {
    ref.listen(repoStatusProvider(arg), (previous, next) {
      if (!identical(previous?.valueOrNull, next.valueOrNull)) _reload();
    });
    _commits = await _fetchPage(0, pageSize);
    return _graphFrom(_commits, await _total());
  }

  Future<List<CommitRecord>> _fetchPage(int skip, int count) async {
    Future<List<CommitRecord>> runLog(List<String> revs) async {
      final r = await GitCli(arg).run([
        'log',
        '--exclude=refs/stash',
        ...revs,
        '--date-order',
        '--decorate=full',
        '-z',
        '--pretty=format:$commitLogFormat',
        '-n', '$count',
        '--skip=$skip',
      ]);
      return parseLogZ(r.stdout);
    }

    try {
      return await runLog(['--all', 'HEAD']);
    } on GitException {
      // HEAD may be unborn while other refs exist — retry without it; a repo
      // with no commits at all fails again and yields an empty graph.
      try {
        return await runLog(['--all']);
      } on GitException {
        return const [];
      }
    }
  }

  Future<int> _total() async {
    try {
      final r = await GitCli(arg)
          .run(['rev-list', '--count', '--exclude=refs/stash', '--all']);
      return int.tryParse(r.stdout.trim()) ?? 0;
    } on GitException {
      return 0;
    }
  }

  CommitGraph _graphFrom(List<CommitRecord> commits, int total) =>
      CommitGraph(rows: assignLanes(commits), totalCount: total);

  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || current.loadingMore || !current.hasMore) return;
    state = AsyncData(current.copyWith(loadingMore: true));
    final next = await _fetchPage(_commits.length, pageSize);
    if (next.isEmpty) {
      // Total was stale — clamp so hasMore stops firing.
      state = AsyncData(CommitGraph(
          rows: current.rows, totalCount: _commits.length));
      return;
    }
    _commits = [..._commits, ...next];
    state = AsyncData(_graphFrom(_commits, current.totalCount));
  }

  Future<void> _reload() async {
    try {
      final target =
          _commits.length < pageSize ? pageSize : _commits.length;
      _commits = await _fetchPage(0, target);
      state = AsyncData(_graphFrom(_commits, await _total()));
    } catch (_) {
      // keep the previous graph
    }
  }
}

final commitGraphProvider = AsyncNotifierProvider.autoDispose
    .family<CommitGraphNotifier, CommitGraph, String>(CommitGraphNotifier.new);

/// Hash of the commit selected in the graph (drives the detail pane in P3).
class SelectedCommitNotifier extends AutoDisposeFamilyNotifier<String?, String> {
  @override
  String? build(String arg) => null;

  void select(String? hash) => state = hash;
}

final selectedCommitProvider = NotifierProvider.autoDispose
    .family<SelectedCommitNotifier, String?, String>(
        SelectedCommitNotifier.new);
