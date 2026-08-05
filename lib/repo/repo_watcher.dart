import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

import '../git/git_dirs.dart';

/// Watches everything that should trigger a status refresh: the working tree
/// plus the metadata under .git (HEAD, index, refs/, MERGE_HEAD,
/// rebase-merge/ ...). Bursts of events (checkout, rebase) are debounced into
/// a single [onChange]. If native watching fails (e.g. inotify watch limit on
/// a huge tree), falls back to polling.
class RepoWatcher {
  final String repoPath;
  final void Function() onChange;
  final Duration debounce;

  final List<DirectoryWatcher> _watchers = [];
  final List<StreamSubscription<WatchEvent>> _subs = [];
  Timer? _debounceTimer;
  Timer? _poll;
  bool _disposed = false;
  String _gitDir = '';

  RepoWatcher(
    this.repoPath, {
    required this.onChange,
    this.debounce = const Duration(milliseconds: 300),
  });

  Future<void> start() async {
    _gitDir = await resolveGitDir(repoPath);
    _listen(_gitDir, _gitEventFilter);
    _listen(repoPath, _worktreeEventFilter);
  }

  /// Completes when the underlying watchers are fully armed. Events that
  /// happen before this may be missed; the app doesn't need to wait (the
  /// initial status load covers them) but tests do.
  Future<void> get ready => Future.wait(_watchers.map((w) => w.ready));

  bool _gitEventFilter(String path) {
    final rel = p.relative(path, from: _gitDir);
    // High-churn, low-signal parts of .git: object writes and reflog appends
    // never matter on their own — anything user-visible also touches a ref.
    if (rel.startsWith('objects') ||
        rel.startsWith('logs') ||
        rel.startsWith('lfs')) {
      return false;
    }
    // Lockfiles flap while git itself writes; the rename onto the real file
    // still produces an event.
    if (rel.endsWith('.lock')) return false;
    return true;
  }

  bool _worktreeEventFilter(String path) {
    final rel = p.relative(path, from: repoPath);
    return rel != '.git' && !rel.startsWith('.git${p.separator}');
  }

  void _listen(String dir, bool Function(String) filter) {
    final watcher = DirectoryWatcher(dir);
    _watchers.add(watcher);
    _subs.add(watcher.events.listen(
      (event) {
        if (filter(event.path)) _schedule();
      },
      onError: (Object _) => _startPollingFallback(),
      cancelOnError: false,
    ));
  }

  void _schedule() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () {
      if (!_disposed) onChange();
    });
  }

  void _startPollingFallback() {
    if (_disposed || _poll != null) return;
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_disposed) onChange();
    });
  }

  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _poll?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _watchers.clear();
  }
}
