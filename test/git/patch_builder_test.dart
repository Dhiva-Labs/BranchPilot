import 'package:branch_pilot/git/parsers/unified_diff.dart';
import 'package:branch_pilot/git/patch_builder.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure patch-construction tests; the real-git round trips live in
/// hunk_roundtrip_test.dart.
void main() {
  const threeHunkDiff = '''
diff --git a/f.txt b/f.txt
--- a/f.txt
+++ b/f.txt
@@ -1,4 +1,5 @@
 l1
+added early
 l2
 l3
 l4
@@ -10,3 +11,3 @@ middle section
 l10
-l11
+l11 changed
 l12
@@ -20,3 +21,4 @@
 l20
 l21
+added late
 l22
''';

  FileDiff parse() => parseUnifiedDiff(threeHunkDiff).single;

  test('first hunk alone keeps its own coordinates', () {
    final f = parse();
    final patch = buildPatch(f, [f.hunks[0]]);
    expect(patch, '''
--- a/f.txt
+++ b/f.txt
@@ -1,4 +1,5 @@
 l1
+added early
 l2
 l3
 l4
''');
  });

  test('middle hunk alone gets newStart rebased (prior +1 removed)', () {
    final f = parse();
    final patch = buildPatch(f, [f.hunks[1]]);
    expect(patch.split('\n')[2], '@@ -10,3 +10,3 @@ middle section');
  });

  test('last hunk alone rebases over both prior hunks', () {
    final f = parse();
    final patch = buildPatch(f, [f.hunks[2]]);
    // Prior deltas: +1 (hunk0) and 0 (hunk1) are dropped → newStart == 20.
    expect(patch.split('\n')[2], '@@ -20,3 +20,4 @@');
  });

  test('two selected hunks accumulate delta across only themselves', () {
    final f = parse();
    final patch = buildPatch(f, [f.hunks[0], f.hunks[2]]);
    final headers =
        patch.split('\n').where((l) => l.startsWith('@@')).toList();
    expect(headers[0], '@@ -1,4 +1,5 @@');
    expect(headers[1], '@@ -20,3 +21,4 @@');
  });

  test('selection order does not matter (hunks are sorted)', () {
    final f = parse();
    expect(buildPatch(f, [f.hunks[2], f.hunks[0]]),
        buildPatch(f, [f.hunks[0], f.hunks[2]]));
  });

  test('no-newline markers are emitted verbatim', () {
    const raw = '''
diff --git a/f b/f
--- a/f
+++ b/f
@@ -1,2 +1,2 @@
 keep
-old
\\ No newline at end of file
+new
\\ No newline at end of file
''';
    final f = parseUnifiedDiff(raw).single;
    final patch = buildPatch(f, [f.hunks.single]);
    expect(patch, raw.split('\n').skip(1).join('\n'));
  });

  test('CRLF content survives byte-for-byte', () {
    final raw = 'diff --git a/dos.txt b/dos.txt\n'
        '--- a/dos.txt\n'
        '+++ b/dos.txt\n'
        '@@ -1,2 +1,2 @@\n'
        ' keep\r\n'
        '-old\r\n'
        '+new\r\n';
    final f = parseUnifiedDiff(raw).single;
    final patch = buildPatch(f, [f.hunks.single]);
    expect(patch.contains(' keep\r\n'), isTrue);
    expect(patch.contains('-old\r\n'), isTrue);
    expect(patch.contains('+new\r\n'), isTrue);
  });

  test('pure insertion hunk (empty file gains content)', () {
    const raw = '''
diff --git a/new.txt b/new.txt
--- a/new.txt
+++ b/new.txt
@@ -0,0 +1,2 @@
+one
+two
''';
    final f = parseUnifiedDiff(raw).single;
    final patch = buildPatch(f, [f.hunks.single]);
    expect(patch.split('\n')[2], '@@ -0,0 +1,2 @@');
  });

  test('whole-content deletion hunk', () {
    const raw = '''
diff --git a/f b/f
--- a/f
+++ b/f
@@ -1,2 +0,0 @@
-one
-two
''';
    final f = parseUnifiedDiff(raw).single;
    final patch = buildPatch(f, [f.hunks.single]);
    expect(patch.split('\n')[2], '@@ -1,2 +0,0 @@');
  });

  test('new-file diff emits /dev/null on the old side', () {
    const raw = '''
diff --git a/created b/created
new file mode 100644
--- /dev/null
+++ b/created
@@ -0,0 +1,1 @@
+hi
''';
    final f = parseUnifiedDiff(raw).single;
    final patch = buildPatch(f, [f.hunks.single]);
    expect(patch.split('\n')[0], '--- /dev/null');
    expect(patch.split('\n')[1], '+++ b/created');
  });
}
