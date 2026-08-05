/// Parser for `git diff -U3 --no-color` output (also `--cached` and
/// `--no-index` variants): extended headers, hunks, no-newline-at-EOF
/// markers, rename/copy metadata, binary markers.
///
/// Pure Dart. CR characters are preserved in line content so CRLF files
/// round-trip byte-identically through the patch builder.
library;

import 'dart:convert';

enum DiffLineKind { context, addition, deletion, noNewline }

class DiffLine {
  final DiffLineKind kind;

  /// The exact patch line (marker included, no trailing newline) — the patch
  /// builder re-emits this verbatim.
  final String raw;

  final int? oldLineNo;
  final int? newLineNo;

  const DiffLine({
    required this.kind,
    required this.raw,
    this.oldLineNo,
    this.newLineNo,
  });

  /// Line content without the +/-/space marker (display form).
  String get text =>
      kind == DiffLineKind.noNewline ? raw : (raw.isEmpty ? '' : raw.substring(1));
}

class DiffHunk {
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final String heading;
  final List<DiffLine> lines;

  const DiffHunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
    required this.heading,
    required this.lines,
  });

  int get additions =>
      lines.where((l) => l.kind == DiffLineKind.addition).length;
  int get deletions =>
      lines.where((l) => l.kind == DiffLineKind.deletion).length;

  String get header =>
      '@@ -$oldStart,$oldCount +$newStart,$newCount @@'
      '${heading.isEmpty ? '' : ' $heading'}';
}

class FileDiff {
  /// Pre-image path; null means /dev/null (new file).
  final String? oldPath;

  /// Post-image path; null means /dev/null (deleted file).
  final String? newPath;

  final bool isBinary;
  final bool isNew;
  final bool isDeleted;
  final bool isRename;
  final bool isCopy;
  final int? similarity;
  final String? oldMode;
  final String? newMode;
  final List<DiffHunk> hunks;

  const FileDiff({
    this.oldPath,
    this.newPath,
    this.isBinary = false,
    this.isNew = false,
    this.isDeleted = false,
    this.isRename = false,
    this.isCopy = false,
    this.similarity,
    this.oldMode,
    this.newMode,
    this.hunks = const [],
  });

  String get path => newPath ?? oldPath ?? '';
}

List<FileDiff> parseUnifiedDiff(String raw) {
  final lines = raw.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();

  final files = <FileDiff>[];
  var i = 0;
  while (i < lines.length) {
    if (!lines[i].startsWith('diff --git ')) {
      i++;
      continue;
    }
    final gitLine = lines[i];
    i++;

    String? oldPath;
    String? newPath;
    var sawOldHeader = false;
    var sawNewHeader = false;
    var isBinary = false;
    var isNew = false;
    var isDeleted = false;
    var isRename = false;
    var isCopy = false;
    int? similarity;
    String? oldMode;
    String? newMode;
    String? fromPath;
    String? toPath;
    final hunks = <DiffHunk>[];

    while (i < lines.length && !lines[i].startsWith('diff --git ')) {
      final l = lines[i];
      if (l.startsWith('@@ ')) {
        final parsed = _parseHunk(lines, i);
        if (parsed == null) {
          i++;
        } else {
          hunks.add(parsed.$1);
          i = parsed.$2;
        }
        continue;
      }
      if (l.startsWith('--- ')) {
        oldPath = _headerPath(l.substring(4), 'a/');
        sawOldHeader = true;
      } else if (l.startsWith('+++ ')) {
        newPath = _headerPath(l.substring(4), 'b/');
        sawNewHeader = true;
      } else if (l.startsWith('new file mode ')) {
        isNew = true;
        newMode = l.substring('new file mode '.length);
      } else if (l.startsWith('deleted file mode ')) {
        isDeleted = true;
        oldMode = l.substring('deleted file mode '.length);
      } else if (l.startsWith('old mode ')) {
        oldMode = l.substring('old mode '.length);
      } else if (l.startsWith('new mode ')) {
        newMode = l.substring('new mode '.length);
      } else if (l.startsWith('similarity index ')) {
        similarity = int.tryParse(
            l.substring('similarity index '.length).replaceAll('%', ''));
      } else if (l.startsWith('rename from ')) {
        isRename = true;
        fromPath = _unquote(l.substring('rename from '.length));
      } else if (l.startsWith('rename to ')) {
        isRename = true;
        toPath = _unquote(l.substring('rename to '.length));
      } else if (l.startsWith('copy from ')) {
        isCopy = true;
        fromPath = _unquote(l.substring('copy from '.length));
      } else if (l.startsWith('copy to ')) {
        isCopy = true;
        toPath = _unquote(l.substring('copy to '.length));
      } else if (l.startsWith('Binary files ') || l == 'GIT binary patch') {
        isBinary = true;
      }
      i++;
    }

    // Paths: ---/+++ headers win, then rename/copy metadata, then the
    // `diff --git a/X b/Y` heuristic (binary and metadata-only diffs).
    if (!sawOldHeader || !sawNewHeader) {
      final (gOld, gNew) = _parseGitLine(gitLine);
      if (!sawOldHeader) oldPath = fromPath ?? gOld;
      if (!sawNewHeader) newPath = toPath ?? gNew;
    }
    if (isNew) oldPath = null;
    if (isDeleted) newPath = null;

    files.add(FileDiff(
      oldPath: oldPath,
      newPath: newPath,
      isBinary: isBinary,
      isNew: isNew,
      isDeleted: isDeleted,
      isRename: isRename,
      isCopy: isCopy,
      similarity: similarity,
      oldMode: oldMode,
      newMode: newMode,
      hunks: hunks,
    ));
  }
  return files;
}

final _hunkHeader =
    RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: (.*))?$');

(DiffHunk, int)? _parseHunk(List<String> lines, int i) {
  final m = _hunkHeader.firstMatch(lines[i]);
  if (m == null) return null;
  final oldStart = int.parse(m.group(1)!);
  final oldCount = m.group(2) == null ? 1 : int.parse(m.group(2)!);
  final newStart = int.parse(m.group(3)!);
  final newCount = m.group(4) == null ? 1 : int.parse(m.group(4)!);
  final heading = m.group(5) ?? '';

  final body = <DiffLine>[];
  var oldRem = oldCount;
  var newRem = newCount;
  var oldNo = oldStart;
  var newNo = newStart;
  var j = i + 1;
  // Count-based consumption: content lines that *look* like diff markers
  // (e.g. a source line starting with "diff --git") can't break parsing.
  while ((oldRem > 0 || newRem > 0) && j < lines.length) {
    final l = lines[j];
    if (l.startsWith('\\')) {
      body.add(DiffLine(kind: DiffLineKind.noNewline, raw: l));
      j++;
      continue;
    }
    final marker = l.isEmpty ? ' ' : l[0];
    switch (marker) {
      case ' ':
        body.add(DiffLine(
            kind: DiffLineKind.context,
            raw: l.isEmpty ? ' ' : l,
            oldLineNo: oldNo,
            newLineNo: newNo));
        oldNo++;
        newNo++;
        oldRem--;
        newRem--;
      case '-':
        body.add(
            DiffLine(kind: DiffLineKind.deletion, raw: l, oldLineNo: oldNo));
        oldNo++;
        oldRem--;
      case '+':
        body.add(
            DiffLine(kind: DiffLineKind.addition, raw: l, newLineNo: newNo));
        newNo++;
        newRem--;
      default:
        // Malformed / truncated hunk — stop consuming.
        return (
          DiffHunk(
              oldStart: oldStart,
              oldCount: oldCount,
              newStart: newStart,
              newCount: newCount,
              heading: heading,
              lines: body),
          j
        );
    }
    j++;
  }
  // Trailing no-newline marker for the last emitted line.
  while (j < lines.length && lines[j].startsWith('\\')) {
    body.add(DiffLine(kind: DiffLineKind.noNewline, raw: lines[j]));
    j++;
  }
  return (
    DiffHunk(
        oldStart: oldStart,
        oldCount: oldCount,
        newStart: newStart,
        newCount: newCount,
        heading: heading,
        lines: body),
    j
  );
}

String? _headerPath(String s, String prefix) {
  var v = _unquote(s);
  if (v == '/dev/null') return null;
  if (v.startsWith(prefix)) v = v.substring(prefix.length);
  return v;
}

(String?, String?) _parseGitLine(String gitLine) {
  var rest = gitLine.substring('diff --git '.length);
  String? old;
  String? neu;
  if (rest.startsWith('"')) {
    final (value, next) = _readQuoted(rest);
    old = value;
    rest = rest.substring(next).trimLeft();
    neu = rest.startsWith('"') ? _readQuoted(rest).$1 : rest;
  } else {
    final idx = rest.lastIndexOf(' b/');
    if (idx < 0) return (null, null);
    old = rest.substring(0, idx);
    neu = rest.substring(idx + 1);
  }
  String strip(String p, String prefix) =>
      p.startsWith(prefix) ? p.substring(prefix.length) : p;
  return (strip(old, 'a/'), strip(neu, 'b/'));
}

/// Reads a C-style quoted string from the start of [s]; returns the decoded
/// value and the index just past the closing quote. Escapes are accumulated
/// as *bytes* (octal escapes encode raw UTF-8 bytes) and decoded at the end.
(String, int) _readQuoted(String s) {
  final bytes = <int>[];
  String finish() => utf8.decode(bytes, allowMalformed: true);
  var i = 1;
  while (i < s.length) {
    final ch = s[i];
    if (ch == '"') return (finish(), i + 1);
    if (ch == r'\' && i + 1 < s.length) {
      final e = s[i + 1];
      switch (e) {
        case 'n':
          bytes.add(0x0A);
          i += 2;
        case 't':
          bytes.add(0x09);
          i += 2;
        case 'r':
          bytes.add(0x0D);
          i += 2;
        case '"':
          bytes.add(0x22);
          i += 2;
        case r'\':
          bytes.add(0x5C);
          i += 2;
        default:
          // Octal escape \NNN (1-3 digits) — one raw byte.
          final m = RegExp(r'^[0-7]{1,3}').firstMatch(s.substring(i + 1));
          if (m != null) {
            bytes.add(int.parse(m.group(0)!, radix: 8));
            i += 1 + m.group(0)!.length;
          } else {
            bytes.addAll(utf8.encode(e));
            i += 2;
          }
      }
    } else {
      bytes.addAll(utf8.encode(ch));
      i++;
    }
  }
  return (finish(), i);
}

String _unquote(String s) =>
    s.startsWith('"') ? _readQuoted(s).$1 : s;
