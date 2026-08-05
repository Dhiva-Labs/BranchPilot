import 'package:branch_pilot/git/parsers/unified_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two-file diff with multiple hunks and headings', () {
    const raw = '''
diff --git a/lib/a.dart b/lib/a.dart
index 111..222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,4 +1,5 @@ class A {
 one
+inserted
 two
-three
+three!
@@ -20,3 +21,3 @@ void main() {
 x
-y
+z
 w
diff --git a/b.txt b/b.txt
--- a/b.txt
+++ b/b.txt
@@ -1,1 +1,1 @@
-old
+new
''';
    final files = parseUnifiedDiff(raw);
    expect(files, hasLength(2));
    final a = files[0];
    expect(a.path, 'lib/a.dart');
    expect(a.hunks, hasLength(2));
    expect(a.hunks[0].heading, 'class A {');
    expect(a.hunks[0].oldStart, 1);
    expect(a.hunks[0].oldCount, 4);
    expect(a.hunks[0].newCount, 5);
    expect(a.hunks[0].additions, 2);
    expect(a.hunks[0].deletions, 1);
    final lines = a.hunks[0].lines;
    expect(lines[0].kind, DiffLineKind.context);
    expect(lines[0].oldLineNo, 1);
    expect(lines[0].newLineNo, 1);
    expect(lines[1].kind, DiffLineKind.addition);
    expect(lines[1].newLineNo, 2);
    expect(lines[1].oldLineNo, isNull);
    expect(lines[3].kind, DiffLineKind.deletion);
    expect(lines[3].oldLineNo, 3);
    expect(lines[3].text, 'three');
    expect(files[1].hunks.single.lines, hasLength(2));
  });

  test('count omitted means 1', () {
    const raw = '''
diff --git a/x b/x
--- a/x
+++ b/x
@@ -5 +5 @@
-a
+b
''';
    final h = parseUnifiedDiff(raw).single.hunks.single;
    expect(h.oldCount, 1);
    expect(h.newCount, 1);
  });

  test('no-newline-at-EOF markers on both sides', () {
    const raw = '''
diff --git a/f b/f
--- a/f
+++ b/f
@@ -1,2 +1,2 @@
 keep
-old ending
\\ No newline at end of file
+new ending
\\ No newline at end of file
''';
    final h = parseUnifiedDiff(raw).single.hunks.single;
    expect(h.lines.map((l) => l.kind), [
      DiffLineKind.context,
      DiffLineKind.deletion,
      DiffLineKind.noNewline,
      DiffLineKind.addition,
      DiffLineKind.noNewline,
    ]);
    expect(h.lines[2].raw, r'\ No newline at end of file');
  });

  test('new and deleted files map /dev/null to null paths', () {
    const raw = '''
diff --git a/created.txt b/created.txt
new file mode 100644
--- /dev/null
+++ b/created.txt
@@ -0,0 +1,2 @@
+hello
+world
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1,1 +0,0 @@
-bye
''';
    final files = parseUnifiedDiff(raw);
    final created = files[0];
    expect(created.isNew, isTrue);
    expect(created.oldPath, isNull);
    expect(created.newPath, 'created.txt');
    expect(created.newMode, '100644');
    final gone = files[1];
    expect(gone.isDeleted, isTrue);
    expect(gone.newPath, isNull);
    expect(gone.oldPath, 'gone.txt');
  });

  test('pure rename with similarity has no hunks and both paths', () {
    const raw = '''
diff --git a/old name.txt b/new name.txt
similarity index 100%
rename from old name.txt
rename to new name.txt
''';
    final f = parseUnifiedDiff(raw).single;
    expect(f.isRename, isTrue);
    expect(f.similarity, 100);
    expect(f.oldPath, 'old name.txt');
    expect(f.newPath, 'new name.txt');
    expect(f.hunks, isEmpty);
  });

  test('binary marker', () {
    const raw = '''
diff --git a/img.png b/img.png
index 111..222 100644
Binary files a/img.png and b/img.png differ
''';
    final f = parseUnifiedDiff(raw).single;
    expect(f.isBinary, isTrue);
    expect(f.path, 'img.png');
  });

  test('mode-only change parses old and new mode', () {
    const raw = '''
diff --git a/run.sh b/run.sh
old mode 100644
new mode 100755
''';
    final f = parseUnifiedDiff(raw).single;
    expect(f.oldMode, '100644');
    expect(f.newMode, '100755');
    expect(f.path, 'run.sh');
    expect(f.hunks, isEmpty);
  });

  test('quoted paths with escapes decode', () {
    const raw = 'diff --git "a/wei\\303\\237.txt" "b/wei\\303\\237.txt"\n'
        '--- "a/wei\\303\\237.txt"\n'
        '+++ "b/wei\\303\\237.txt"\n'
        '@@ -1,1 +1,1 @@\n'
        '-a\n'
        '+b\n';
    final f = parseUnifiedDiff(raw).single;
    expect(f.path, 'weiß.txt');
  });

  test('CR is preserved in line content (CRLF files)', () {
    final raw = 'diff --git a/dos.txt b/dos.txt\n'
        '--- a/dos.txt\n'
        '+++ b/dos.txt\n'
        '@@ -1,2 +1,2 @@\n'
        ' keep\r\n'
        '-old\r\n'
        '+new\r\n';
    final h = parseUnifiedDiff(raw).single.hunks.single;
    expect(h.lines[0].raw, ' keep\r');
    expect(h.lines[1].raw, '-old\r');
    expect(h.lines[2].raw, '+new\r');
  });

  test('content lines that look like diff markers do not break parsing', () {
    const raw = '''
diff --git a/notes.md b/notes.md
--- a/notes.md
+++ b/notes.md
@@ -1,3 +1,4 @@
 intro
+diff --git a/fake b/fake
 --- not a header
 +++ also not
''';
    final f = parseUnifiedDiff(raw).single;
    expect(f.hunks.single.lines, hasLength(4));
    expect(f.hunks.single.lines[1].text, 'diff --git a/fake b/fake');
    expect(f.hunks.single.lines[2].kind, DiffLineKind.context);
  });

  test('empty context line with missing trailing space still counts', () {
    // Some tools emit a completely empty line for empty context lines.
    const raw = '''
diff --git a/f b/f
--- a/f
+++ b/f
@@ -1,3 +1,3 @@
 a

-b
+c
''';
    final h = parseUnifiedDiff(raw).single.hunks.single;
    expect(h.lines, hasLength(4));
    expect(h.lines[1].kind, DiffLineKind.context);
  });

  test('empty input yields no files', () {
    expect(parseUnifiedDiff(''), isEmpty);
  });
}
