import 'package:branch_pilot/git/parsers/log_parser.dart';
import 'package:flutter_test/flutter_test.dart';

String rec({
  String hash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String parents = '',
  String an = 'Alice',
  String ae = 'alice@example.com',
  String at = '1753700000',
  String d = '',
  String s = 'a subject',
}) =>
    [hash, parents, an, ae, at, d, s].join('\x1f');

void main() {
  group('parseLogZ', () {
    test('parses a stream of records with and without trailing NUL', () {
      final raw = [
        rec(hash: 'c3', parents: 'c2', s: 'third'),
        rec(hash: 'c2', parents: 'c1', s: 'second'),
        rec(hash: 'c1', parents: '', s: 'first'),
      ].join('\x00');
      for (final input in [raw, '$raw\x00']) {
        final commits = parseLogZ(input);
        expect(commits, hasLength(3));
        expect(commits[0].hash, 'c3');
        expect(commits[0].parents, ['c2']);
        expect(commits[2].parents, isEmpty);
        expect(commits[2].subject, 'first');
      }
    });

    test('merge commit has multiple parents and isMerge', () {
      final commits = parseLogZ(rec(hash: 'm1', parents: 'p1 p2'));
      expect(commits.single.parents, ['p1', 'p2']);
      expect(commits.single.isMerge, isTrue);
    });

    test('author fields and unix date decode', () {
      final commits =
          parseLogZ(rec(an: 'Bob', ae: 'bob@x.dev', at: '1700000000'));
      final c = commits.single;
      expect(c.authorName, 'Bob');
      expect(c.authorEmail, 'bob@x.dev');
      expect(c.authorDate.toUtc().year, 2023);
    });

    test('empty input yields no commits', () {
      expect(parseLogZ(''), isEmpty);
    });

    test('handles subject with spaces and unicode', () {
      final commits = parseLogZ(rec(s: 'fix: übergroße Änderung 🎉'));
      expect(commits.single.subject, 'fix: übergroße Änderung 🎉');
    });
  });

  group('parseDecorations', () {
    test('current branch, remote, tag (full ref names)', () {
      final refs = parseDecorations(
          'HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0.0');
      expect(refs, hasLength(3));
      expect(refs[0].name, 'main');
      expect(refs[0].kind, RefKind.localBranch);
      expect(refs[0].isCurrent, isTrue);
      expect(refs[1].name, 'origin/main');
      expect(refs[1].kind, RefKind.remoteBranch);
      expect(refs[1].isCurrent, isFalse);
      expect(refs[2].name, 'v1.0.0');
      expect(refs[2].kind, RefKind.tag);
    });

    test('detached HEAD decoration', () {
      final refs = parseDecorations('HEAD, refs/heads/main');
      expect(refs[0].name, 'HEAD');
      expect(refs[0].kind, RefKind.head);
      expect(refs[1].kind, RefKind.localBranch);
      expect(refs[1].isCurrent, isFalse);
    });

    test('branch names containing slashes stay local branches', () {
      final refs = parseDecorations('refs/heads/feature/fancy-thing');
      expect(refs.single.name, 'feature/fancy-thing');
      expect(refs.single.kind, RefKind.localBranch);
    });

    test('empty decoration', () {
      expect(parseDecorations(''), isEmpty);
    });
  });
}
