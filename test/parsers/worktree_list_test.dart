import 'package:branch_pilot/git/parsers/worktree_list.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds `git worktree list --porcelain -z` output from a list of records,
/// each a list of attribute lines (e.g. `'worktree /path'`, `'HEAD abc123'`,
/// `'branch refs/heads/main'`). Every attribute is NUL-terminated and each
/// record ends with an extra empty entry (the blank-line separator) — see
/// git-worktree(1), "PORCELAIN FORMAT", and the doc comment on
/// [parseWorktreeListZ].
String buildWorktreeZ(List<List<String>> records) {
  final tokens = <String>[];
  for (final r in records) {
    tokens.addAll(r);
    tokens.add('');
  }
  return tokens.join('\x00');
}

void main() {
  group('parseWorktreeListZ', () {
    test('main worktree + a linked worktree, both on a branch', () {
      final raw = buildWorktreeZ([
        ['worktree /repo', 'HEAD aaa1111', 'branch refs/heads/main'],
        ['worktree /repo-wt1', 'HEAD bbb2222', 'branch refs/heads/feature'],
      ]);
      final items = parseWorktreeListZ(raw);
      expect(items, hasLength(2));

      expect(items[0].path, '/repo');
      expect(items[0].headOid, 'aaa1111');
      expect(items[0].branch, 'main');
      expect(items[0].bare, isFalse);
      expect(items[0].detached, isFalse);
      expect(items[0].locked, isFalse);
      expect(items[0].prunable, isFalse);

      expect(items[1].path, '/repo-wt1');
      expect(items[1].headOid, 'bbb2222');
      expect(items[1].branch, 'feature');
    });

    test('a detached worktree has no branch attribute but sets detached', () {
      final raw = buildWorktreeZ([
        ['worktree /repo', 'HEAD aaa1111', 'branch refs/heads/main'],
        ['worktree /repo-detached', 'HEAD bbb2222', 'detached'],
      ]);
      final items = parseWorktreeListZ(raw);
      expect(items, hasLength(2));

      final detached = items[1];
      expect(detached.path, '/repo-detached');
      expect(detached.headOid, 'bbb2222');
      expect(detached.branch, isNull);
      expect(detached.detached, isTrue);
      expect(detached.bare, isFalse);
    });

    test('a bare repository has no HEAD/branch attribute, only bare', () {
      final raw = buildWorktreeZ([
        ['worktree /bare.git', 'bare'],
      ]);
      final items = parseWorktreeListZ(raw);
      expect(items, hasLength(1));

      final bare = items.single;
      expect(bare.path, '/bare.git');
      expect(bare.bare, isTrue);
      expect(bare.headOid, isNull);
      expect(bare.branch, isNull);
      expect(bare.detached, isFalse);
    });

    test('locked with a reason still sets the plain locked flag', () {
      final raw = buildWorktreeZ([
        ['worktree /repo', 'HEAD aaa1111', 'branch refs/heads/main'],
        [
          'worktree /repo-locked',
          'HEAD bbb2222',
          'branch refs/heads/lockme',
          'locked testing lock reason',
        ],
      ]);
      final items = parseWorktreeListZ(raw);
      expect(items, hasLength(2));
      final locked = items[1];
      expect(locked.locked, isTrue);
      expect(locked.prunable, isFalse);
      expect(locked.branch, 'lockme');
    });

    test('locked with no reason at all also sets locked', () {
      final raw = buildWorktreeZ([
        [
          'worktree /repo-locked',
          'HEAD aaa1111',
          'branch refs/heads/x',
          'locked',
        ],
      ]);
      expect(parseWorktreeListZ(raw).single.locked, isTrue);
    });

    test('prunable with a reason sets the plain prunable flag', () {
      final raw = buildWorktreeZ([
        [
          'worktree /repo-gone',
          'HEAD aaa1111',
          'branch refs/heads/gone',
          'prunable gitdir file points to non-existent location',
        ],
      ]);
      final items = parseWorktreeListZ(raw);
      expect(items.single.prunable, isTrue);
      expect(items.single.locked, isFalse);
    });

    test('empty input yields no worktrees', () {
      expect(parseWorktreeListZ(''), isEmpty);
    });

    test('a lone stray NUL with no attributes yields no worktrees', () {
      expect(parseWorktreeListZ('\x00'), isEmpty);
    });

    test('the real-git trailing double-NUL shape parses correctly', () {
      // What `git worktree list --porcelain -z` actually emits: every line —
      // including the final blank-line separator — is its own
      // NUL-terminated token, so the raw stream ends in two consecutive
      // NULs rather than one.
      const raw =
          'worktree /repo\x00HEAD aaa1111\x00branch refs/heads/main\x00\x00';
      final items = parseWorktreeListZ(raw);
      expect(items, hasLength(1));
      expect(items.single.path, '/repo');
      expect(items.single.branch, 'main');
    });

    test(
        'three real-git-shaped records back to back (main, detached, linked) '
        'with the trailing double NUL', () {
      const raw = 'worktree /repo\x00'
          'HEAD aaa1111\x00'
          'branch refs/heads/main\x00'
          '\x00'
          'worktree /repo-detached\x00'
          'HEAD bbb2222\x00'
          'detached\x00'
          '\x00'
          'worktree /repo-wt1\x00'
          'HEAD ccc3333\x00'
          'branch refs/heads/feature-wt\x00'
          '\x00';
      final items = parseWorktreeListZ(raw);
      expect(items, hasLength(3));
      expect(items[0].path, '/repo');
      expect(items[0].branch, 'main');
      expect(items[1].path, '/repo-detached');
      expect(items[1].detached, isTrue);
      expect(items[1].branch, isNull);
      expect(items[2].path, '/repo-wt1');
      expect(items[2].branch, 'feature-wt');
    });

    test('an unknown attribute is ignored defensively', () {
      final raw = buildWorktreeZ([
        ['worktree /repo', 'HEAD aaa1111', 'branch refs/heads/main', 'future-attr something'],
      ]);
      final items = parseWorktreeListZ(raw);
      expect(items, hasLength(1));
      expect(items.single.path, '/repo');
      expect(items.single.branch, 'main');
    });
  });
}
