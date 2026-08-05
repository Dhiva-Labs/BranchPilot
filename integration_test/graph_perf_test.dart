import 'package:branch_pilot/git/parsers/lane_assignment.dart';
import 'package:branch_pilot/git/parsers/log_parser.dart';
import 'package:branch_pilot/ui/graph/commit_graph_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Scroll-performance check: a 5000-commit synthetic graph must fling
/// smoothly on the real Linux embedder (fixed row extent + cheap painters).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  List<CommitRecord> syntheticDag(int n) {
    CommitRecord c(String hash, List<String> parents, String subject) =>
        CommitRecord(
          hash: hash,
          parents: parents,
          authorName: 'Perf Bot',
          authorEmail: 'perf@test',
          authorDate: DateTime(2026, 1, 1),
          refs: const [],
          subject: subject,
        );
    final forward = <CommitRecord>[c('n0', [], 'root')];
    for (var i = 1; i < n; i++) {
      final parents = <String>['n${i - 1}'];
      if (i % 11 == 0 && i >= 7) parents.add('n${i - 7}');
      if (i % 23 == 0 && i >= 5) {
        parents
          ..clear()
          ..add('n${i - 5}');
      }
      forward.add(c('n$i', parents, 'commit number $i with some subject'));
    }
    return forward.reversed.toList();
  }

  testWidgets('5k-row graph list flings through hundreds of rows quickly',
      (tester) async {
    final rows = assignLanes(syntheticDag(5000));
    expect(rows, hasLength(5000));

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4C8DFF), brightness: Brightness.dark),
      ),
      home: Scaffold(body: GraphList(rows: rows)),
    ));
    await tester.pumpAndSettle();

    final sw = Stopwatch()..start();
    for (var i = 0; i < 4; i++) {
      await tester.fling(
          find.byType(ListView), const Offset(0, -2400), 8000);
      await tester.pumpAndSettle();
    }
    sw.stop();

    // Four hard flings across a 5k list — generous debug-mode budget.
    expect(sw.elapsedMilliseconds, lessThan(8000),
        reason: 'flinging a 5k graph should not jank (took ${sw.elapsed})');

    // We actually travelled deep into the list.
    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scrollable.position.pixels, greaterThan(3000));
  });
}
