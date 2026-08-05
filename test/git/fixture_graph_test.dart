@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/parsers/lane_assignment.dart';
import 'package:branch_pilot/git/parsers/log_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// End-to-end graph pipeline against real git: fixture history with
/// deterministic committer dates → the app's log command → parseLogZ →
/// assignLanes.
void main() {
  late Directory tmp;

  Future<void> g(List<String> args, {int? t}) async =>
      GitCli(tmp.path).run(args,
          environment: t == null
              ? null
              : {
                  'GIT_AUTHOR_DATE': '2026-01-01T00:00:$t +0000',
                  'GIT_COMMITTER_DATE': '2026-01-01T00:00:$t +0000',
                });

  Future<void> write(String rel, String content) =>
      File(p.join(tmp.path, rel)).writeAsString(content);

  Future<List<GraphRow>> graphRows() async {
    final r = await GitCli(tmp.path).run([
      'log',
      '--exclude=refs/stash',
      '--all',
      'HEAD',
      '--date-order',
      '--decorate=full',
      '-z',
      '--pretty=format:$commitLogFormat',
      '-n', '500',
    ]);
    return assignLanes(parseLogZ(r.stdout));
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_graph_');
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'graph@test.local']);
    await g(['config', 'user.name', 'Graph']);
    await g(['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('merge history produces the expected lanes, refs and order', () async {
    // A(t=10) root — B(t=20) on main — C(t=30) on feature — M(t=40) merge.
    await write('f.txt', 'a\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'A'], t: 10);
    await write('main.txt', 'b\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'B'], t: 20);
    await g(['checkout', '-q', '-b', 'feature', 'HEAD~1']);
    await write('feat.txt', 'c\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'C'], t: 30);
    await g(['checkout', '-q', 'main']);
    await g(['merge', '--no-ff', '-m', 'M', 'feature'], t: 40);

    final rows = await graphRows();
    expect(rows.map((r) => r.commit.subject), ['M', 'C', 'B', 'A']);

    final m = rows[0], cRow = rows[1], b = rows[2], a = rows[3];
    // Shape: M(lane0, fan-out to 0+1) / C(lane1) / B(lane0) / A(join 0+1).
    expect(m.lane, 0);
    expect(m.commit.isMerge, isTrue);
    expect(m.forksOut, [0, 1]);
    expect(cRow.lane, 1);
    expect(cRow.continuing, [0]);
    expect(b.lane, 0);
    expect(b.continuing, [1]);
    expect(a.lane, 0);
    expect(a.mergesIn, [0, 1]);
    expect(a.forksOut, isEmpty);

    // Decorations: M carries current-branch main, C carries feature.
    final mRefs = m.commit.refs;
    expect(mRefs.any((r) => r.name == 'main' && r.isCurrent), isTrue);
    expect(cRow.commit.refs.any((r) => r.name == 'feature'), isTrue);
  });

  test('tags and detached HEAD decorate correctly through the pipeline',
      () async {
    await write('f.txt', 'a\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'A'], t: 10);
    await g(['tag', '-a', 'v1.0', '-m', 'v1.0']);
    await write('f.txt', 'b\n');
    await g(['commit', '-am', 'B'], t: 20);
    await g(['checkout', '-q', '--detach', 'HEAD']);

    final rows = await graphRows();
    expect(rows, hasLength(2));
    final tagged = rows[1];
    expect(tagged.commit.refs.any((r) => r.kind == RefKind.tag && r.name == 'v1.0'),
        isTrue);
    final head = rows[0];
    expect(head.commit.refs.any((r) => r.kind == RefKind.head), isTrue);
  });

  test('stash commits are excluded from the graph', () async {
    await write('f.txt', 'a\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'A'], t: 10);
    await write('f.txt', 'dirty\n');
    await g(['stash', 'push', '-m', 'wip']);

    final rows = await graphRows();
    expect(rows.map((r) => r.commit.subject), ['A']);
  });
}
