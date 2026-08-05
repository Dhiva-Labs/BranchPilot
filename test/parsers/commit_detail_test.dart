import 'package:branch_pilot/git/parsers/commit_detail.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a raw `git show -s --format=$commitMetaFormat` record: fields
/// joined on 0x1f, in the exact order commitMetaFormat requests them.
String rec({
  String hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String parents = '',
  String an = 'Alice',
  String ae = 'alice@example.com',
  String at = '1753700000',
  String cn = 'Alice',
  String ct = '1753700000',
  String d = '',
  String b = 'a subject',
}) =>
    [hash, parents, an, ae, at, cn, ct, d, b].join('\x1f');

void main() {
  group('parseCommitMeta', () {
    test('parses hash, parents, author, committer, refs, subject and body',
        () {
      final meta = parseCommitMeta(rec(
        hash: 'c1',
        parents: 'p1 p2',
        an: 'Alice',
        ae: 'alice@example.com',
        cn: 'Bob',
        d: 'HEAD -> refs/heads/main',
        b: 'Subject line\n\nBody line 1\nBody line 2',
      ));
      expect(meta, isNotNull);
      expect(meta!.hash, 'c1');
      expect(meta.parents, ['p1', 'p2']);
      expect(meta.authorName, 'Alice');
      expect(meta.authorEmail, 'alice@example.com');
      expect(meta.committerName, 'Bob');
      expect(meta.refs, 'HEAD -> refs/heads/main');
      expect(meta.subject, 'Subject line');
      expect(meta.body, 'Body line 1\nBody line 2');
    });

    test('root commit has no parents', () {
      final meta = parseCommitMeta(rec(parents: ''));
      expect(meta!.parents, isEmpty);
    });

    test('merge commit has multiple parents', () {
      final meta = parseCommitMeta(rec(parents: 'p1 p2 p3'));
      expect(meta!.parents, ['p1', 'p2', 'p3']);
    });

    test('author and committer unix timestamps decode independently', () {
      final meta =
          parseCommitMeta(rec(at: '1700000000', ct: '1700003600'));
      expect(meta!.authorDate.toUtc().year, 2023);
      expect(meta.committerDate.difference(meta.authorDate).inHours, 1);
    });

    test('multiline body is preserved exactly, including inner blank lines',
        () {
      final meta = parseCommitMeta(
          rec(b: 'Subject line\n\nBody line 1\n\nBody line 2'));
      expect(meta!.subject, 'Subject line');
      expect(meta.body, 'Body line 1\n\nBody line 2');
    });

    test('subject-only message (no blank line, no body) yields empty body',
        () {
      final meta = parseCommitMeta(rec(b: 'Just a subject, nothing else'));
      expect(meta!.subject, 'Just a subject, nothing else');
      expect(meta.body, '');
    });

    test('trailing blank lines after the body are trimmed', () {
      final meta = parseCommitMeta(rec(b: 'Subject\n\nBody text\n\n\n'));
      expect(meta!.subject, 'Subject');
      expect(meta.body, 'Body text');
    });

    test('empty input yields null', () {
      expect(parseCommitMeta(''), isNull);
    });

    test('too few fields (malformed) yields null', () {
      expect(parseCommitMeta('only\x1ftwo'), isNull);
    });

    test('shortHash truncates to 7 characters', () {
      final meta =
          parseCommitMeta(rec(hash: 'deadbeefcafefeedfacefeedfacefeedfaceface'));
      expect(meta!.shortHash, 'deadbee');
    });

    test('shortHash leaves an already-short hash untouched', () {
      final meta = parseCommitMeta(rec(hash: 'abc123'));
      expect(meta!.shortHash, 'abc123');
    });
  });

  group('parseNumstatZ', () {
    test('normal entries carry added/deleted/path', () {
      final out = ['3\t1\tfile.txt', '10\t0\tother/path.dart'].join('\x00');
      final stats = parseNumstatZ(out);
      expect(stats, hasLength(2));
      expect(stats[0].path, 'file.txt');
      expect(stats[0].added, 3);
      expect(stats[0].deleted, 1);
      expect(stats[0].binary, isFalse);
      expect(stats[0].oldPath, isNull);
      expect(stats[1].path, 'other/path.dart');
      expect(stats[1].added, 10);
      expect(stats[1].deleted, 0);
    });

    test(
        'rename triple: empty-path record followed by source then dest NUL '
        'tokens', () {
      final out = ['4\t2\t', 'old/path.txt', 'new/path.txt'].join('\x00');
      final stats = parseNumstatZ(out);
      expect(stats, hasLength(1));
      expect(stats.single.added, 4);
      expect(stats.single.deleted, 2);
      expect(stats.single.oldPath, 'old/path.txt');
      expect(stats.single.path, 'new/path.txt');
    });

    test('binary marker (dash dash) yields binary true and null counts', () {
      final stats = parseNumstatZ('-\t-\timg.png');
      expect(stats, hasLength(1));
      expect(stats.single.binary, isTrue);
      expect(stats.single.added, isNull);
      expect(stats.single.deleted, isNull);
      expect(stats.single.path, 'img.png');
    });

    test('binary rename also carries oldPath', () {
      final out = ['-\t-\t', 'old.png', 'new.png'].join('\x00');
      final stats = parseNumstatZ(out);
      expect(stats.single.binary, isTrue);
      expect(stats.single.oldPath, 'old.png');
      expect(stats.single.path, 'new.png');
    });

    test('mixed list (normal, rename, binary, delete-only) preserves order',
        () {
      final out = [
        '1\t2\ta.txt',
        '4\t2\t', 'old.txt', 'new.txt', // rename
        '-\t-\tbinary.bin',
        '0\t5\tdeleted.txt',
      ].join('\x00');
      final stats = parseNumstatZ(out);
      expect(stats.map((s) => s.path),
          ['a.txt', 'new.txt', 'binary.bin', 'deleted.txt']);
      expect(stats[0].oldPath, isNull);
      expect(stats[1].oldPath, 'old.txt');
      expect(stats[2].binary, isTrue);
      expect(stats[3].added, 0);
      expect(stats[3].deleted, 5);
    });

    test('trailing NUL is tolerated (no spurious empty entry)', () {
      final stats = parseNumstatZ('1\t1\tfile.txt\x00');
      expect(stats, hasLength(1));
      expect(stats.single.path, 'file.txt');
    });

    test('empty input yields no entries', () {
      expect(parseNumstatZ(''), isEmpty);
    });

    test('malformed record without two tabs is skipped defensively', () {
      final out = ['not-a-numstat-line', '1\t1\tok.txt'].join('\x00');
      final stats = parseNumstatZ(out);
      expect(stats, hasLength(1));
      expect(stats.single.path, 'ok.txt');
    });
  });
}
