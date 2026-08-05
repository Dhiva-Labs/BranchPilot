/// Parsers for a single historical commit's metadata and per-file stats,
/// used by the P3 commit-detail panel.
///
/// Pure Dart, no dart:io — see git-show(1).
library;

/// `--format=` string for [parseCommitMeta] (fields split on 0x1f):
///
///   `git show -s --format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ct%x1f%D%x1f%B <hash>`
const commitMetaFormat =
    '%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ct%x1f%D%x1f%B';

class CommitMeta {
  final String hash;
  final List<String> parents;
  final String authorName;
  final String authorEmail;
  final DateTime authorDate;
  final String committerName;
  final DateTime committerDate;

  /// Raw `%D` decoration string (kept simple — the graph already has a full
  /// decoration parser in log_parser.dart; the detail panel doesn't need
  /// anything richer than the raw text).
  final String refs;

  final String subject;
  final String body;

  const CommitMeta({
    required this.hash,
    required this.parents,
    required this.authorName,
    required this.authorEmail,
    required this.authorDate,
    required this.committerName,
    required this.committerDate,
    required this.refs,
    required this.subject,
    required this.body,
  });

  String get shortHash => hash.length >= 7 ? hash.substring(0, 7) : hash;
}

/// Splits a raw commit message into `(subject, body)`: subject is the first
/// line; body is everything after the first blank line, trimmed of trailing
/// whitespace. Text between the subject and that first blank line (an
/// unconventional message shape with no blank-line separator) belongs to
/// neither and is dropped — mirrors how the app treats "subject" and "body"
/// as the two things a user edits, everything else being the conventional
/// blank-line-separated shape `git commit` itself produces.
(String, String) splitSubjectBody(String raw) {
  final firstNl = raw.indexOf('\n');
  if (firstNl == -1) return (raw, '');
  final subject = raw.substring(0, firstNl);
  final lines = raw.split('\n');
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].isEmpty) {
      return (subject, lines.sublist(i + 1).join('\n').trimRight());
    }
  }
  return (subject, '');
}

/// Parses the output of `git show -s --format=$commitMetaFormat <hash>`.
/// Returns null on malformed/empty input (fewer than the 9 expected fields).
CommitMeta? parseCommitMeta(String raw) {
  if (raw.isEmpty) return null;
  final f = raw.split('\x1f');
  if (f.length < 9) return null;
  // %B is last and may (in theory) contain the 0x1f field separator itself;
  // join any extra splits back — same defensive trick as log_parser subject.
  final bodyRaw = f.sublist(8).join('\x1f');
  final (subject, body) = splitSubjectBody(bodyRaw);
  return CommitMeta(
    hash: f[0],
    parents: f[1].isEmpty ? const [] : f[1].split(' '),
    authorName: f[2],
    authorEmail: f[3],
    authorDate:
        DateTime.fromMillisecondsSinceEpoch((int.tryParse(f[4]) ?? 0) * 1000),
    committerName: f[5],
    committerDate:
        DateTime.fromMillisecondsSinceEpoch((int.tryParse(f[6]) ?? 0) * 1000),
    refs: f[7],
    subject: subject,
    body: body,
  );
}

class FileStat {
  final String path;

  /// Rename/copy source path; null for a non-rename entry.
  final String? oldPath;

  /// Added/deleted line counts; null for a binary file (numstat prints `-`).
  final int? added;
  final int? deleted;
  final bool binary;

  const FileStat({
    required this.path,
    this.oldPath,
    this.added,
    this.deleted,
    this.binary = false,
  });
}

/// Parses `git show --numstat --format= -z <hash>` output.
///
/// With `-z`, each record is NUL-terminated. A normal record is a single
/// token `ADDED\tDELETED\tPATH` (`ADDED`/`DELETED` are `-` for a binary
/// file). A rename/copy record has an *empty* path after the second tab,
/// followed by two more NUL-separated tokens: the source path, then the
/// destination path. Written defensively: malformed/truncated records are
/// skipped rather than thrown on.
List<FileStat> parseNumstatZ(String zOutput) {
  final tokens = zOutput.split('\x00');
  final stats = <FileStat>[];
  var i = 0;
  while (i < tokens.length) {
    final t = tokens[i];
    i++;
    if (t.isEmpty) continue; // trailing NUL, or a stray empty token

    final firstTab = t.indexOf('\t');
    if (firstTab < 0) continue; // malformed — skip defensively
    final secondTab = t.indexOf('\t', firstTab + 1);
    if (secondTab < 0) continue; // malformed — skip defensively

    final addedStr = t.substring(0, firstTab);
    final deletedStr = t.substring(firstTab + 1, secondTab);
    final path = t.substring(secondTab + 1);
    final binary = addedStr == '-' && deletedStr == '-';
    final added = binary ? null : int.tryParse(addedStr);
    final deleted = binary ? null : int.tryParse(deletedStr);

    if (path.isEmpty) {
      // Rename/copy: the next two NUL tokens are source, then dest.
      if (i >= tokens.length) break;
      final source = tokens[i];
      i++;
      if (i >= tokens.length) break;
      final dest = tokens[i];
      i++;
      stats.add(FileStat(
        path: dest,
        oldPath: source,
        added: added,
        deleted: deleted,
        binary: binary,
      ));
    } else {
      stats.add(FileStat(
        path: path,
        added: added,
        deleted: deleted,
        binary: binary,
      ));
    }
  }
  return stats;
}
