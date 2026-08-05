import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'repo/providers.dart';
import 'ui/home_screen.dart';
import 'ui/open_repo.dart';
import 'ui/repo_workspace.dart';

class BranchPilotApp extends StatelessWidget {
  /// Repository paths passed on the command line, opened at startup.
  final List<String> initialRepoPaths;

  const BranchPilotApp({super.key, this.initialRepoPaths = const []});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4C8DFF);
    return MaterialApp(
      title: 'BranchPilot',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF14171D),
        dividerTheme:
            DividerThemeData(color: Colors.white.withValues(alpha: 0.08)),
        listTileTheme: const ListTileThemeData(dense: true),
      ),
      home: Launcher(initialRepoPaths: initialRepoPaths),
    );
  }
}

class Launcher extends ConsumerStatefulWidget {
  final List<String> initialRepoPaths;

  const Launcher({super.key, this.initialRepoPaths = const []});

  @override
  ConsumerState<Launcher> createState() => _LauncherState();
}

class _LauncherState extends ConsumerState<Launcher> {
  @override
  void initState() {
    super.initState();
    if (widget.initialRepoPaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        for (final path in widget.initialRepoPaths) {
          if (!mounted) return;
          await openRepository(context, ref, path: path);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(openReposProvider);
    return Scaffold(
      body: open.isEmpty ? const HomeScreen() : const RepoWorkspace(),
    );
  }
}
