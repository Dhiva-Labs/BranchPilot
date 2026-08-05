import 'package:branch_pilot/git/parsers/lane_assignment.dart';
import 'package:branch_pilot/git/parsers/log_parser.dart';
import 'package:flutter_test/flutter_test.dart';

CommitRecord c(String hash, List<String> parents) => CommitRecord(
      hash: hash,
      parents: parents,
      authorName: 'a',
      authorEmail: 'a@a',
      authorDate: DateTime.fromMillisecondsSinceEpoch(0),
      refs: const [],
      subject: hash,
    );

void expectRow(
  GraphRow row, {
  required int lane,
  required List<int> mergesIn,
  required List<int> forksOut,
  required List<int> continuing,
  required int laneCount,
}) {
  expect(row.lane, lane, reason: '${row.commit.hash} lane');
  expect(row.mergesIn, mergesIn, reason: '${row.commit.hash} mergesIn');
  expect(row.forksOut, forksOut, reason: '${row.commit.hash} forksOut');
  expect(row.continuing, continuing, reason: '${row.commit.hash} continuing');
  expect(row.laneCount, laneCount, reason: '${row.commit.hash} laneCount');
}

void main() {
  test('linear history stays in lane 0', () {
    final rows = assignLanes([
      c('C', ['B']),
      c('B', ['A']),
      c('A', []),
    ]);
    expectRow(rows[0],
        lane: 0, mergesIn: [], forksOut: [0], continuing: [], laneCount: 1);
    expectRow(rows[1],
        lane: 0, mergesIn: [0], forksOut: [0], continuing: [], laneCount: 1);
    expectRow(rows[2],
        lane: 0, mergesIn: [0], forksOut: [], continuing: [], laneCount: 1);
  });

  test('fork: two children of one commit converge at the fork point', () {
    // A ← B ← C (tip), B ← D (tip)
    final rows = assignLanes([
      c('C', ['B']),
      c('D', ['B']),
      c('B', ['A']),
      c('A', []),
    ]);
    expectRow(rows[0],
        lane: 0, mergesIn: [], forksOut: [0], continuing: [], laneCount: 1);
    expectRow(rows[1],
        lane: 1, mergesIn: [], forksOut: [1], continuing: [0], laneCount: 2);
    expectRow(rows[2],
        lane: 0,
        mergesIn: [0, 1],
        forksOut: [0],
        continuing: [],
        laneCount: 2);
    expectRow(rows[3],
        lane: 0, mergesIn: [0], forksOut: [], continuing: [], laneCount: 1);
  });

  test('merge: second parent gets its own lane until the base', () {
    // A ← B (main), A ← C (feature), M = merge(B, C)
    final rows = assignLanes([
      c('M', ['B', 'C']),
      c('C', ['A']),
      c('B', ['A']),
      c('A', []),
    ]);
    expectRow(rows[0],
        lane: 0, mergesIn: [], forksOut: [0, 1], continuing: [], laneCount: 2);
    expectRow(rows[1],
        lane: 1, mergesIn: [1], forksOut: [1], continuing: [0], laneCount: 2);
    expectRow(rows[2],
        lane: 0, mergesIn: [0], forksOut: [0], continuing: [1], laneCount: 2);
    expectRow(rows[3],
        lane: 0,
        mergesIn: [0, 1],
        forksOut: [],
        continuing: [],
        laneCount: 2);
  });

  test('criss-cross: merge edge routes into an existing expecting lane', () {
    // A ← B, A ← C, M1 = merge(B, C), M2 = merge(C, B)
    final rows = assignLanes([
      c('M2', ['C', 'B']),
      c('M1', ['B', 'C']),
      c('C', ['A']),
      c('B', ['A']),
      c('A', []),
    ]);
    expectRow(rows[0],
        lane: 0, mergesIn: [], forksOut: [0, 1], continuing: [], laneCount: 2);
    // M1 is its own tip; its second-parent edge reuses lane 0 (criss-cross):
    // lane 0 both continues and receives the merge edge.
    expectRow(rows[1],
        lane: 2,
        mergesIn: [],
        forksOut: [2, 0],
        continuing: [0, 1],
        laneCount: 3);
    expectRow(rows[2],
        lane: 0,
        mergesIn: [0],
        forksOut: [0],
        continuing: [1, 2],
        laneCount: 3);
    expectRow(rows[3],
        lane: 1,
        mergesIn: [1, 2],
        forksOut: [1],
        continuing: [0],
        laneCount: 3);
    expectRow(rows[4],
        lane: 0,
        mergesIn: [0, 1],
        forksOut: [],
        continuing: [],
        laneCount: 2);
  });

  test('octopus merge fans out one lane per parent', () {
    final rows = assignLanes([
      c('O', ['P1', 'P2', 'P3']),
      c('P1', []),
      c('P2', []),
      c('P3', []),
    ]);
    expectRow(rows[0],
        lane: 0,
        mergesIn: [],
        forksOut: [0, 1, 2],
        continuing: [],
        laneCount: 3);
    expectRow(rows[1],
        lane: 0,
        mergesIn: [0],
        forksOut: [],
        continuing: [1, 2],
        laneCount: 3);
    expectRow(rows[2],
        lane: 1, mergesIn: [1], forksOut: [], continuing: [2], laneCount: 3);
    expectRow(rows[3],
        lane: 2, mergesIn: [2], forksOut: [], continuing: [], laneCount: 3);
  });

  test('independent roots reuse freed lanes', () {
    final rows = assignLanes([
      c('A1', []),
      c('A2', []),
    ]);
    expectRow(rows[0],
        lane: 0, mergesIn: [], forksOut: [], continuing: [], laneCount: 1);
    expectRow(rows[1],
        lane: 0, mergesIn: [], forksOut: [], continuing: [], laneCount: 1);
  });

  test('every edge is drawable: forks and merges reference valid lanes', () {
    // Slightly larger pseudo-random DAG exercising invariants.
    final commits = <CommitRecord>[];
    // Build forward (oldest first), then reverse into date-order.
    final forward = <CommitRecord>[c('n0', [])];
    for (var i = 1; i < 200; i++) {
      final parents = <String>['n${i - 1}'];
      if (i % 13 == 0 && i >= 6) parents.add('n${i - 6}');
      if (i % 17 == 0 && i >= 4) {
        parents
          ..clear()
          ..add('n${i - 4}');
      }
      forward.add(c('n$i', parents));
    }
    commits.addAll(forward.reversed);
    final rows = assignLanes(commits);
    expect(rows, hasLength(200));
    for (final r in rows) {
      expect(r.lane, lessThan(r.laneCount));
      for (final f in r.forksOut) {
        expect(f, lessThan(r.laneCount));
      }
      for (final m in r.mergesIn) {
        expect(m, lessThan(r.laneCount));
      }
      for (final k in r.continuing) {
        expect(k, lessThan(r.laneCount));
      }
      if (r.commit.parents.isNotEmpty) {
        expect(r.forksOut.first, r.lane,
            reason: 'first parent continues in the node lane');
        expect(r.forksOut, hasLength(r.commit.parents.length));
      }
    }
  });

  test('assignLanes over 5000 commits is fast', () {
    final forward = <CommitRecord>[c('n0', [])];
    for (var i = 1; i < 5000; i++) {
      final parents = <String>['n${i - 1}'];
      if (i % 11 == 0 && i >= 7) parents.add('n${i - 7}');
      forward.add(c('n$i', parents));
    }
    final commits = forward.reversed.toList();
    final sw = Stopwatch()..start();
    final rows = assignLanes(commits);
    sw.stop();
    expect(rows, hasLength(5000));
    expect(sw.elapsedMilliseconds, lessThan(500),
        reason: 'lane assignment must stay trivial at 5k commits');
  });
}
