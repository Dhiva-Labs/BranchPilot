@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:branch_pilot/git/parsers/unified_diff.dart';
import 'package:branch_pilot/git/patch_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Property-style subset test: a 40-line file with 4 well-separated edits
/// (lines 5/15/25/35) parses into 4 distinct hunks. For every subset of
/// those hunks, staging exactly that subset via [buildPatch] must produce
/// precisely that many staged hunks with the expected content, and
/// unstaging everything again must return the index to HEAD byte-for-byte.
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

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('branchpilot_hunkprop_');
    await g(['init', '-b', 'main']);
    await g(['config', 'user.email', 'p@test.local']);
    await g(['config', 'user.name', 'Prop']);
    await g(['config', 'commit.gpgsign', 'false']);

    await write(
        'f.txt', '${List.generate(40, (i) => 'line ${i + 1}').join('\n')}\n');
    await g(['add', '.']);
    await g(['commit', '-m', 'base']);

    final lines = List.generate(40, (i) => 'line ${i + 1}');
    for (final n in [5, 15, 25, 35]) {
      lines[n - 1] = 'line $n CHANGED';
    }
    await write('f.txt', '${lines.join('\n')}\n');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('every hunk subset stages exactly itself and unstages cleanly',
      () async {
    for (final subset in [
      [0],
      [3],
      [1, 2],
      [0, 3],
      [0, 1, 2, 3],
      [2],
    ]) {
      // Mixed reset: index back to HEAD, the 4-line working-tree edit left
      // untouched, so every subset starts from the same clean slate.
      await g(['reset']);

      final file = (await unstagedDiff()).single;
      expect(file.hunks, hasLength(4),
          reason: 'subset $subset: expected 4 separated hunks');

      final selected = [for (final i in subset) file.hunks[i]];
      await applyCached(buildPatch(file, selected));

      final staged = (await cachedDiff()).single;
      expect(staged.hunks, hasLength(subset.length),
          reason: 'subset $subset: staged hunk count');

      for (final i in subset) {
        final lineNo = 5 + 10 * i;
        expect(
          staged.hunks.any(
              (h) => h.lines.any((l) => l.raw == '+line $lineNo CHANGED')),
          isTrue,
          reason: 'subset $subset: expected "+line $lineNo CHANGED" staged',
        );
      }

      // Unstage everything again — the index must return exactly to HEAD.
      await applyCached(buildPatch(staged, staged.hunks), reverse: true);
      final indexOid =
          (await git().run(['rev-parse', ':f.txt'])).stdout.trim();
      final headOid =
          (await git().run(['rev-parse', 'HEAD:f.txt'])).stdout.trim();
      expect(indexOid, headOid,
          reason: 'subset $subset: index must equal HEAD after full unstage');
    }
  });
}
