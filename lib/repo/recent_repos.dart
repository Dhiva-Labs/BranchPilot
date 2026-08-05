import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Most-recently-used repository paths, persisted across launches.
class RecentReposNotifier extends AsyncNotifier<List<String>> {
  static const _prefsKey = 'recentRepos';
  static const _maxEntries = 15;

  @override
  Future<List<String>> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_prefsKey) ?? const [];
  }

  Future<void> add(String path) async {
    final list = [...(state.valueOrNull ?? const <String>[])];
    list.remove(path);
    list.insert(0, path);
    while (list.length > _maxEntries) {
      list.removeLast();
    }
    await _save(list);
  }

  Future<void> remove(String path) async {
    final list = [...(state.valueOrNull ?? const <String>[])]..remove(path);
    await _save(list);
  }

  Future<void> _save(List<String> list) async {
    state = AsyncData(list);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, list);
  }
}

final recentReposProvider =
    AsyncNotifierProvider<RecentReposNotifier, List<String>>(
        RecentReposNotifier.new);
