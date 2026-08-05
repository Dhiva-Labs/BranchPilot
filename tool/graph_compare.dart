// Prints BranchPilot's lane assignment next to `git log --graph` for the
// same repository, for visual topology verification.
//
//   dart run tool/graph_compare.dart <repo-path> [count] [skip]
import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/parsers/lane_assignment.dart';
import 'package:branch_pilot/git/parsers/log_parser.dart';

Future<void> main(List<String> args) async {
  final repo = args.isNotEmpty ? args.first : Directory.current.path;
  final count = args.length > 1 ? int.parse(args[1]) : 30;
  final skip = args.length > 2 ? int.parse(args[2]) : 0;
  final git = GitCli(repo);

  // Note: lanes are assigned from row 0, so we fetch skip+count and print
  // only the tail — that keeps the lane state identical to the app's.
  final r = await git.run([
    'log',
    '--exclude=refs/stash',
    '--all',
    'HEAD',
    '--date-order',
    '--decorate=full',
    '-z',
    '--pretty=format:$commitLogFormat',
    '-n', '${skip + count}',
  ]);
  final rows = assignLanes(parseLogZ(r.stdout));
  stdout.writeln('=== BranchPilot lanes ($repo, skip=$skip) ===');
  final ascii = rowsToAscii(rows).split('\n');
  stdout.writeln(ascii.skip(skip).take(count).join('\n'));

  stdout.writeln('=== git log --graph ===');
  final g = await git.run([
    'log',
    '--graph',
    '--oneline',
    '--no-decorate',
    '--exclude=refs/stash',
    '--all',
    'HEAD',
    '--date-order',
    '-n', '${skip + count}',
  ]);
  final gLines = g.stdout.split('\n');
  // Git's graph lines include pure edge rows (no commit); skip by counting
  // rows that contain a commit marker '*'.
  var seen = 0;
  final out = <String>[];
  for (final line in gLines) {
    final isCommit = line.contains('* ');
    if (isCommit) seen++;
    if (seen > skip && out.length < count * 2) out.add(line);
    if (seen >= skip + count) break;
  }
  stdout.writeln(out.join('\n'));
}
