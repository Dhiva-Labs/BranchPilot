import 'dart:io';
import 'dart:ui' as ui;

import 'package:branch_pilot/git/parsers/lane_assignment.dart';
import 'package:branch_pilot/git/parsers/log_parser.dart';
import 'package:branch_pilot/ui/graph/commit_graph_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Renders the graph widget for a gnarly synthetic DAG and dumps a PNG for
/// human inspection (the lane algorithm itself is asserted in
/// lane_assignment_test.dart — this covers the painter).
void main() {
  CommitRecord c(String hash, List<String> parents, String subject,
          {List<RefName> refs = const []}) =>
      CommitRecord(
        hash: hash,
        parents: parents,
        authorName: 'Dhivakar',
        authorEmail: 'd@test',
        authorDate: DateTime(2026, 7, 28),
        refs: refs,
        subject: subject,
      );

  testWidgets('paint criss-cross + merge + octopus graph to PNG',
      (tester) async {
    final commits = [
      c('M2', ['C', 'B'], 'Merge B into C (criss-cross 2)', refs: const [
        RefName('main', RefKind.localBranch, isCurrent: true),
        RefName('origin/main', RefKind.remoteBranch),
      ]),
      c('M1', ['B', 'C'], 'Merge C into B (criss-cross 1)', refs: const [
        RefName('experiment', RefKind.localBranch),
      ]),
      c('C', ['A'], 'Feature work on C', refs: const [
        RefName('v0.2.0', RefKind.tag),
      ]),
      c('B', ['A'], 'Feature work on B'),
      c('A', [], 'Initial commit'),
      c('O', ['P1', 'P2', 'P3'], 'Octopus merge of three lines'),
      c('P1', [], 'Line one'),
      c('P2', [], 'Line two'),
      c('P3', [], 'Line three'),
    ];
    final rows = assignLanes(commits);

    const key = ValueKey('boundary');
    await tester.binding.setSurfaceSize(const Size(780, 340));
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4C8DFF), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF14171D),
      ),
      home: Scaffold(
        body: RepaintBoundary(
          key: key,
          child: GraphList(rows: rows, selectedHash: 'M1'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });

    final out = p.join(Directory.systemTemp.path, 'branchpilot_visual');
    Directory(out).createSync(recursive: true);
    final file = File(p.join(out, 'graph_synthetic.png'));
    file.writeAsBytesSync(bytes!);
    // ignore: avoid_print
    print('graph render dumped to ${file.path}');
    expect(bytes.length, greaterThan(1000));
  });
}
