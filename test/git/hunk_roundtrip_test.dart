@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/parsers/unified_diff.dart';
import 'package:branch_pilot/git/patch_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The P2 acceptance tests: staging a hunk via a reconstructed patch and
/// `git apply --cached`, then unstaging with `-R`, must leave the index
/// byte-identical.
void main() {
  late Directory tmp;

  GitCli git() => GitCli(tmp.path);

  Future<void> g(List<String> args) async => git().run(args);

  Future<void> write(String rel, String content) =>
      File(p.join(tmp.path, rel)).writeAsString(content, flush: true);

  Future<List<FileDiff>> unstagedDiff() async {
    final r = await git().run(['diff', '-U3', '--no-color']);
    return parseUnifiedDiff(r.stdout);
  }

  Future<List<FileDiff>> cachedDiff() async {
    final r = await git().run(['diff', '-U3', '--no-color', '--cached']);
    return parseUnifiedDiff(r.stdout);
  }

  Future<void> applyCached(String patch, {bool reverse = false}) async {
    await git().run(
      ['apply', '--cached', if (reverse) '-R', '-'],
      stdin: utf8.encode(patch),
    );
  }

  /// Blob id of the staged version of [path].
  Future<String> indexBlob(String path) async =>
      (await git().run(['rev-parse', ':$path'])).stdout.trim();

  Future<String> headBlob(String path) async =>
      (await git().run(['rev-parse', 'HEAD:$path'])).stdout.trim();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_hunks_');
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'h@test.local']);
    await g(['config', 'user.name', 'Hunks']);
    await g(['config', 'commit.gpgsign', 'false']);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<void> commitThirtyLines() async {
    await write(
        'f.txt', '${List.generate(30, (i) => 'line ${i + 1}').join('\n')}\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
  }

  Future<void> modifyThreeRegions() async {
    final lines = List.generate(30, (i) => 'line ${i + 1}');
    lines[2] = 'line 3 CHANGED';
    lines[14] = 'line 15 CHANGED';
    lines[26] = 'line 27 CHANGED';
    await write('f.txt', '${lines.join('\n')}\n');
  }

  test('stage a middle hunk alone, then unstage — index byte-identical',
      () async {
    await commitThirtyLines();
    await modifyThreeRegions();

    final before = await indexBlob('f.txt');
    final file = (await unstagedDiff()).single;
    expect(file.hunks, hasLength(3));

    await applyCached(buildPatch(file, [file.hunks[1]]));

    // Index now contains exactly the middle change.
    final staged = (await cachedDiff()).single;
    expect(staged.hunks, hasLength(1));
    expect(
        staged.hunks.single.lines
            .any((l) => l.raw == '+line 15 CHANGED'),
        isTrue);
    expect(
        staged.hunks.single.lines.any((l) => l.raw.contains('line 3 CHANGED')),
        isFalse);

    // Unstage it again from the cached diff.
    await applyCached(buildPatch(staged, [staged.hunks.single]),
        reverse: true);
    expect(await indexBlob('f.txt'), before);
    expect(await indexBlob('f.txt'), await headBlob('f.txt'));
    expect((await cachedDiff()), isEmpty);
  });

  test('first and last hunks round-trip too', () async {
    await commitThirtyLines();
    await modifyThreeRegions();
    final before = await indexBlob('f.txt');

    for (final which in [0, 2]) {
      final file = (await unstagedDiff()).single;
      await applyCached(buildPatch(file, [file.hunks[which]]));
      final staged = (await cachedDiff()).single;
      expect(staged.hunks, hasLength(1));
      await applyCached(buildPatch(staged, [staged.hunks.single]),
          reverse: true);
      expect(await indexBlob('f.txt'), before,
          reason: 'hunk $which round trip must restore the index');
    }
  });

  test('staging all hunks one at a time equals staging the file', () async {
    await commitThirtyLines();
    await modifyThreeRegions();

    // Stage hunk-by-hunk, re-reading the diff each time (coordinates of the
    // remaining hunks change as the index moves).
    while (true) {
      final files = await unstagedDiff();
      if (files.isEmpty) break;
      final file = files.single;
      await applyCached(buildPatch(file, [file.hunks.first]));
    }
    final worktreeVsIndex =
        await git().run(['diff', '--no-color']);
    expect(worktreeVsIndex.stdout.trim(), isEmpty);
    final staged = (await cachedDiff()).single;
    expect(staged.hunks, hasLength(3));
  });

  test('no-newline-at-EOF file round-trips', () async {
    await write('f.txt', 'a\nb\nlast without newline'); // no trailing \n
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
    await write('f.txt', 'a\nb\nlast CHANGED still no newline');

    final before = await indexBlob('f.txt');
    final file = (await unstagedDiff()).single;
    final hunk = file.hunks.single;
    expect(
        hunk.lines.where((l) => l.kind == DiffLineKind.noNewline).length, 2);

    await applyCached(buildPatch(file, [hunk]));
    final staged = (await cachedDiff()).single;
    await applyCached(buildPatch(staged, [staged.hunks.single]),
        reverse: true);
    expect(await indexBlob('f.txt'), before);
  });

  test('CRLF file round-trips byte-identically', () async {
    await write('dos.txt', 'one\r\ntwo\r\nthree\r\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
    await write('dos.txt', 'one\r\nTWO changed\r\nthree\r\n');

    final before = await indexBlob('dos.txt');
    final file = (await unstagedDiff()).single;
    await applyCached(buildPatch(file, [file.hunks.single]));

    final staged = (await cachedDiff()).single;
    expect(staged.hunks.single.lines.any((l) => l.raw == '+TWO changed\r'),
        isTrue);
    await applyCached(buildPatch(staged, [staged.hunks.single]),
        reverse: true);
    expect(await indexBlob('dos.txt'), before);
  });

  test('emptied file and refilled empty file round-trip', () async {
    await write('f.txt', 'one\ntwo\n');
    await write('empty.txt', '');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);
    await write('f.txt', '');
    await write('empty.txt', 'now\nfull\n');

    final before1 = await indexBlob('f.txt');
    final before2 = await indexBlob('empty.txt');
    final files = await unstagedDiff();
    final emptied = files.firstWhere((f) => f.path == 'f.txt');
    final filled = files.firstWhere((f) => f.path == 'empty.txt');

    await applyCached(buildPatch(emptied, [emptied.hunks.single]));
    await applyCached(buildPatch(filled, [filled.hunks.single]));

    final staged = await cachedDiff();
    expect(staged, hasLength(2));
    for (final f in staged) {
      await applyCached(buildPatch(f, [f.hunks.single]), reverse: true);
    }
    expect(await indexBlob('f.txt'), before1);
    expect(await indexBlob('empty.txt'), before2);
  });
}
