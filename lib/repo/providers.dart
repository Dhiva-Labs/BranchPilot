import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../git/git_cli.dart';
import '../git/parsers/porcelain_status.dart';
import 'repo_watcher.dart';

/// Paths of repositories open in this window, in tab order.
class OpenReposNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void open(String path) {
    if (!state.contains(path)) state = [...state, path];
    ref.read(activeRepoProvider.notifier).set(path);
  }

  void close(String path) {
    state = state.where((e) => e != path).toList();
    if (ref.read(activeRepoProvider) == path) {
      ref
          .read(activeRepoProvider.notifier)
          .set(state.isEmpty ? null : state.last);
    }
  }
}

final openReposProvider =
    NotifierProvider<OpenReposNotifier, List<String>>(OpenReposNotifier.new);

class ActiveRepoNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? path) => state = path;
}

final activeRepoProvider =
    NotifierProvider<ActiveRepoNotifier, String?>(ActiveRepoNotifier.new);

/// Live working-tree status for one repository. The workspace watches every
/// open repo, which keeps the provider (and its file watcher) alive; closing
/// the tab drops the last listener and tears the watcher down.
class RepoStatusNotifier
    extends AutoDisposeFamilyAsyncNotifier<StatusSnapshot, String> {
  @override
  Future<StatusSnapshot> build(String arg) async {
    final watcher = RepoWatcher(arg, onChange: refresh);
    ref.onDispose(watcher.dispose);
    await watcher.start();
    return _load();
  }

  Future<StatusSnapshot> _load() async {
    final r =
        await GitCli(arg).run(['status', '--porcelain=v2', '--branch', '-z']);
    return parsePorcelainV2(r.stdout);
  }

  /// Refreshes in place: no loading flicker, and the previous snapshot is
  /// kept if git is momentarily unhappy (mid-operation lock contention).
  Future<void> refresh() async {
    try {
      state = AsyncData(await _load());
    } catch (_) {
      // keep the last good snapshot
    }
  }
}

final repoStatusProvider = AsyncNotifierProvider.autoDispose
    .family<RepoStatusNotifier, StatusSnapshot, String>(RepoStatusNotifier.new);
