import 'package:branch_pilot/git/parsers/porcelain_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// Joins records the way `git status -z` emits them: NUL-terminated.
String z(List<String> tokens) => '${tokens.join('\x00')}\x00';

const mode = '100644';
const h = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('branch headers', () {
    test('branch with upstream and ahead/behind', () {
      final s = parsePorcelainV2(z([
        '# branch.oid 1234567890abcdef1234567890abcdef12345678',
        '# branch.head main',
        '# branch.upstream origin/main',
        '# branch.ab +3 -1',
      ]));
      expect(s.branch.oid, startsWith('12345678'));
      expect(s.branch.head, 'main');
      expect(s.branch.detached, isFalse);
      expect(s.branch.upstream, 'origin/main');
      expect(s.branch.ahead, 3);
      expect(s.branch.behind, 1);
      expect(s.entries, isEmpty);
      expect(s.isClean, isTrue);
    });

    test('detached HEAD', () {
      final s = parsePorcelainV2(z([
        '# branch.oid $h',
        '# branch.head (detached)',
      ]));
      expect(s.branch.detached, isTrue);
      expect(s.branch.head, isNull);
      expect(s.branch.oid, h);
    });

    test('unborn branch (no commits yet)', () {
      final s = parsePorcelainV2(z([
        '# branch.oid (initial)',
        '# branch.head main',
      ]));
      expect(s.branch.initial, isTrue);
      expect(s.branch.oid, isNull);
      expect(s.branch.head, 'main');
    });

    test('empty output parses to a clean snapshot', () {
      final s = parsePorcelainV2('');
      expect(s.entries, isEmpty);
      expect(s.branch.head, isNull);
    });
  });

  group('ordinary entries', () {
    test('staged modification (M.)', () {
      final s = parsePorcelainV2(
          z(['1 M. N... $mode $mode $mode $h $h lib/main.dart']));
      final e = s.entries.single;
      expect(e.path, 'lib/main.dart');
      expect(e.indexState, FileState.modified);
      expect(e.worktreeState, FileState.unmodified);
      expect(e.hasStagedChange, isTrue);
      expect(e.hasWorktreeChange, isFalse);
      expect(s.staged, hasLength(1));
      expect(s.unstaged, isEmpty);
    });

    test('unstaged modification (.M)', () {
      final s =
          parsePorcelainV2(z(['1 .M N... $mode $mode $mode $h $h a.txt']));
      final e = s.entries.single;
      expect(e.hasStagedChange, isFalse);
      expect(e.hasWorktreeChange, isTrue);
      expect(s.unstaged.single.path, 'a.txt');
    });

    test('modified in both index and worktree (MM) appears in both lists',
        () {
      final s =
          parsePorcelainV2(z(['1 MM N... $mode $mode $mode $h $h a.txt']));
      expect(s.staged.single.path, 'a.txt');
      expect(s.unstaged.single.path, 'a.txt');
    });

    test('staged new file (A.)', () {
      final s =
          parsePorcelainV2(z(['1 A. N... 000000 $mode $mode 0000 $h new.txt']));
      expect(s.entries.single.indexState, FileState.added);
      expect(s.staged, hasLength(1));
    });

    test('unstaged deletion (.D)', () {
      final s =
          parsePorcelainV2(z(['1 .D N... $mode $mode 000000 $h $h gone.txt']));
      expect(s.entries.single.worktreeState, FileState.deleted);
    });

    test('staged deletion (D.)', () {
      final s =
          parsePorcelainV2(z(['1 D. N... $mode 000000 000000 $h 0000 gone.txt']));
      expect(s.entries.single.indexState, FileState.deleted);
    });

    test('path containing spaces', () {
      final s = parsePorcelainV2(
          z(['1 .M N... $mode $mode $mode $h $h my dir/my file.txt']));
      expect(s.entries.single.path, 'my dir/my file.txt');
    });

    test('submodule entry is flagged', () {
      final s = parsePorcelainV2(
          z(['1 .M SC.. 160000 160000 160000 $h $h vendor/sub']));
      expect(s.entries.single.isSubmodule, isTrue);
    });
  });

  group('renames', () {
    test('staged rename carries score and original path', () {
      final s = parsePorcelainV2(z([
        '2 R. N... $mode $mode $mode $h $h R100 lib/new name.dart',
        'lib/old name.dart',
      ]));
      final e = s.entries.single;
      expect(e.path, 'lib/new name.dart');
      expect(e.origPath, 'lib/old name.dart');
      expect(e.renameScore, 100);
      expect(e.indexState, FileState.renamed);
      expect(s.staged, hasLength(1));
    });

    test('copy record parses like a rename', () {
      final s = parsePorcelainV2(z([
        '2 C. N... $mode $mode $mode $h $h C75 copy.txt',
        'source.txt',
      ]));
      final e = s.entries.single;
      expect(e.indexState, FileState.copied);
      expect(e.renameScore, 75);
      expect(e.origPath, 'source.txt');
    });
  });

  group('unmerged / untracked / ignored', () {
    test('both-modified conflict (UU)', () {
      final s = parsePorcelainV2(z([
        'u UU N... $mode $mode $mode $mode $h $h $h conflict.txt',
      ]));
      final e = s.entries.single;
      expect(e.unmerged, isTrue);
      expect(e.path, 'conflict.txt');
      expect(s.conflicted, hasLength(1));
      expect(s.hasConflicts, isTrue);
      // A conflicted entry is neither staged nor unstaged.
      expect(s.staged, isEmpty);
      expect(s.unstaged, isEmpty);
    });

    test('untracked file', () {
      final s = parsePorcelainV2(z(['? junk.txt']));
      final e = s.entries.single;
      expect(e.untracked, isTrue);
      expect(e.indexState, FileState.untracked);
      expect(s.untracked.single.path, 'junk.txt');
      expect(s.staged, isEmpty);
    });

    test('untracked path with spaces', () {
      final s = parsePorcelainV2(z(['? new dir/file name']));
      expect(s.untracked.single.path, 'new dir/file name');
    });

    test('ignored entry', () {
      final s = parsePorcelainV2(z(['! build/']));
      final e = s.entries.single;
      expect(e.ignored, isTrue);
      expect(s.untracked, isEmpty);
      expect(s.staged, isEmpty);
    });
  });

  test('full mixed listing keeps every entry with correct grouping', () {
    final s = parsePorcelainV2(z([
      '# branch.oid $h',
      '# branch.head main',
      '1 M. N... $mode $mode $mode $h $h staged.txt',
      '1 .M N... $mode $mode $mode $h $h unstaged.txt',
      '2 R. N... $mode $mode $mode $h $h R90 renamed.txt',
      'original.txt',
      'u UU N... $mode $mode $mode $mode $h $h $h conflict.txt',
      '? fresh.txt',
    ]));
    expect(s.entries, hasLength(5));
    expect(s.staged.map((e) => e.path), containsAll(['staged.txt', 'renamed.txt']));
    expect(s.unstaged.map((e) => e.path), ['unstaged.txt']);
    expect(s.conflicted.map((e) => e.path), ['conflict.txt']);
    expect(s.untracked.map((e) => e.path), ['fresh.txt']);
  });
}
