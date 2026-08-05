@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The P3 acceptance tests for commit creation. Exercises the exact git
/// command path `CommitOps` uses — `git commit [--amend] -F -` fed the
/// message over stdin — directly against a real git fixture, the same way
/// hunk_roundtrip_test.dart exercises `git apply --cached` directly rather
/// than going through the Riverpod notifier that wraps it (CommitOps itself
/// needs a WidgetRef, which only a pumped widget tree can supply — that's
/// what integration_test/commit_flow_test.dart covers).
void main() {
  late Directory tmp;

  GitCli git() => GitCli(tmp.path);

  Future<void> g(List<String> args) async => git().run(args);

  Future<void> write(String rel, String content) =>
      File(p.join(tmp.path, rel)).writeAsString(content, flush: true);

  /// Exactly what `CommitOps.commit()` runs: `git commit [--amend] -F -`
  /// with the utf8-encoded message on stdin.
  Future<void> commitViaStdin(String message, {bool amend = false}) async {
    await git().run(
      ['commit', if (amend) '--amend', '-F', '-'],
      stdin: utf8.encode(message),
    );
  }

  Future<String> lastMessage() async =>
      (await git().run(['log', '-1', '--pretty=%B'])).stdout;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_commit_');
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'c@test.local']);
    await g(['config', 'user.name', 'Committer']);
    await g(['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('subject + multiline body survive `-F -` byte-exactly', () async {
    await write('f.txt', 'one\n');
    await g(['add', '.']);

    const subject = 'feat: add greeting';
    const body = 'Longer explanation.\n\nWith a second paragraph.';
    await commitViaStdin('$subject\n\n$body');

    final logged = (await lastMessage()).trimRight();
    expect(logged, '$subject\n\n$body');
  });

  test('subject with no body round-trips with no stray blank lines', () async {
    await write('f.txt', 'one\n');
    await g(['add', '.']);
    await commitViaStdin('fix: a small thing');
    expect((await lastMessage()).trimRight(), 'fix: a small thing');
  });

  test(
      'amend replaces the message, keeps one commit, and absorbs the staged '
      'change', () async {
    await write('f.txt', 'one\n');
    await g(['add', '.']);
    await commitViaStdin('feat: first change');
    final firstHash = (await git().run(['rev-parse', 'HEAD'])).stdout.trim();

    await write('f.txt', 'one\ntwo\n');
    await g(['add', '.']);
    await commitViaStdin('feat: first change amended', amend: true);

    expect((await lastMessage()).trimRight(), 'feat: first change amended');

    final count =
        (await git().run(['rev-list', '--count', 'HEAD'])).stdout.trim();
    expect(count, '1');

    final newHash = (await git().run(['rev-parse', 'HEAD'])).stdout.trim();
    expect(newHash, isNot(firstHash),
        reason: 'amend must produce a new commit object, not mutate in place');

    final cached = (await git().run(['diff', '--cached'])).stdout;
    expect(cached.trim(), isEmpty,
        reason: 'the staged change was absorbed into the amended commit');

    final headContent = (await git().run(['show', 'HEAD:f.txt'])).stdout;
    expect(headContent, 'one\ntwo\n');
  });

  test(
      "a leading '#' line in the body survives `-F -` (default cleanup is "
      "'whitespace', not 'strip', for -F/-m) — verified against real git, "
      'not assumed', () async {
    await write('f.txt', 'one\n');
    await g(['add', '.']);

    const subject = 'fix: something';
    const body = '# This looks like a comment\nActual detail line.';
    await commitViaStdin('$subject\n\n$body');

    final logged = (await lastMessage()).trimRight();
    expect(logged, '$subject\n\n$body');
    expect(logged.contains('# This looks like a comment'), isTrue);
  });

  test('leading/trailing blank lines in the raw stdin message are stripped '
      "by git's default whitespace cleanup", () async {
    await write('f.txt', 'one\n');
    await g(['add', '.']);
    // Deliberately pad with extra blank lines the way naive concatenation
    // never would, to observe git's own cleanup rather than assert on our
    // own trimming.
    await commitViaStdin('\n\nSubject\n\nBody\n\n\n');
    expect((await lastMessage()).trimRight(), 'Subject\n\nBody');
  });
}
