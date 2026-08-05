/// Lane assignment for the commit graph.
///
/// Input: commits in `--date-order` (children always before parents).
/// Output: one [GraphRow] per commit with everything a row painter needs.
///
/// The algorithm keeps a list of active lanes; each lane holds the hash of
/// the commit it expects next. A commit lands in the leftmost lane expecting
/// it (extra expecting lanes converge into the node and are freed); its first
/// parent inherits the node's lane, and each additional parent either routes
/// to an existing lane already expecting it or claims the first free lane.
/// Pure Dart — heavily unit-tested on synthetic DAGs.
library;

import 'log_parser.dart';

class GraphRow {
  final CommitRecord commit;

  /// Lane index of the node bullet.
  final int lane;

  /// Lanes whose line from the row above joins this node. Contains [lane]
  /// itself iff the node's own lane had a line coming from above (i.e. some
  /// child below-in-history/above-in-list expected this commit).
  final List<int> mergesIn;

  /// Lanes this node's parent edges occupy below. Contains [lane] itself iff
  /// the commit has parents (first parent continues in the node's lane).
  final List<int> forksOut;

  /// Lanes that pass straight through this row without touching the node.
  /// (A lane can appear both here and in [forksOut]: a merge edge may route
  /// into a lane that is also continuing — the criss-cross case.)
  final List<int> continuing;

  /// Number of lane slots this row needs horizontally.
  final int laneCount;

  const GraphRow({
    required this.commit,
    required this.lane,
    required this.mergesIn,
    required this.forksOut,
    required this.continuing,
    required this.laneCount,
  });
}

int _alloc(List<String?> lanes) {
  final free = lanes.indexOf(null);
  if (free != -1) return free;
  lanes.add(null);
  return lanes.length - 1;
}

List<GraphRow> assignLanes(List<CommitRecord> commits) {
  final lanes = <String?>[]; // lane index -> hash expected next in that lane
  final rows = <GraphRow>[];

  for (final c in commits) {
    final before = List<String?>.of(lanes);

    // Lanes waiting for this commit (edges from already-drawn children).
    final waiting = <int>[
      for (var i = 0; i < lanes.length; i++)
        if (lanes[i] == c.hash) i
    ];

    final int lane;
    if (waiting.isEmpty) {
      lane = _alloc(lanes); // a tip: branch head not reached by any child yet
    } else {
      lane = waiting.first;
      for (final i in waiting.skip(1)) {
        lanes[i] = null; // converge into the node, free the lane
      }
    }

    // Parents: first parent continues in the node's lane; each further parent
    // routes to a lane that already expects it, or claims a free one.
    final forksOut = <int>[];
    if (c.parents.isEmpty) {
      lanes[lane] = null; // root commit — lane ends here
    } else {
      lanes[lane] = c.parents.first;
      forksOut.add(lane);
      for (final p in c.parents.skip(1)) {
        final existing = lanes.indexOf(p);
        if (existing != -1) {
          forksOut.add(existing);
        } else {
          final l = _alloc(lanes);
          lanes[l] = p;
          forksOut.add(l);
        }
      }
    }

    // Straight pass-through lines: active above, not part of this node.
    final continuing = <int>[
      for (var i = 0; i < before.length; i++)
        if (before[i] != null && !waiting.contains(i)) i
    ];

    // Trim trailing free lanes so laneCount doesn't stay inflated forever.
    while (lanes.isNotEmpty && lanes.last == null) {
      lanes.removeLast();
    }

    rows.add(GraphRow(
      commit: c,
      lane: lane,
      mergesIn: waiting,
      forksOut: forksOut,
      continuing: continuing,
      laneCount: [
        before.length,
        lanes.length,
        lane + 1,
        for (final f in forksOut) f + 1,
      ].reduce((a, b) => a > b ? a : b),
    ));
  }
  return rows;
}

/// Renders rows as ASCII for debugging/verification against
/// `git log --graph` — node as `*`, pass-through as `|`.
String rowsToAscii(List<GraphRow> rows, {int? maxRows}) {
  final buf = StringBuffer();
  for (final r in rows.take(maxRows ?? rows.length)) {
    final width = r.laneCount;
    final cells = List.filled(width, ' ');
    for (final c in r.continuing) {
      if (c < width) cells[c] = '|';
    }
    for (final m in r.mergesIn) {
      if (m != r.lane && m < width) cells[m] = '.';
    }
    for (final f in r.forksOut) {
      if (f != r.lane && f < width && cells[f] == ' ') cells[f] = "'";
    }
    cells[r.lane] = '*';
    buf.writeln(
        '${cells.join(' ')}  ${r.commit.shortHash} ${r.commit.subject}');
  }
  return buf.toString();
}
