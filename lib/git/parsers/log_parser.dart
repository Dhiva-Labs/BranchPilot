/// Parser for the commit-graph log stream:
///
///   git log --exclude=refs/stash --all HEAD --date-order --decorate=full -z
///       --pretty=format:%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s
///
/// Records are NUL-separated (-z), fields split on 0x1f. Pure Dart.
library;

/// `--pretty=format:` string for the graph log stream (fields split on 0x1f).
const commitLogFormat = '%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s';

enum RefKind { head, localBranch, remoteBranch, tag, other }

class RefName {
  /// Short display name (e.g. `main`, `origin/main`, `v1.0.0`, `HEAD`).
  final String name;
  final RefKind kind;

  /// True for the `HEAD -> branch` decoration (the checked-out branch).
  final bool isCurrent;

  const RefName(this.name, this.kind, {this.isCurrent = false});

  @override
  String toString() => name;
}

class CommitRecord {
  final String hash;
  final List<String> parents;
  final String authorName;
  final String authorEmail;
  final DateTime authorDate;
  final List<RefName> refs;
  final String subject;

  const CommitRecord({
    required this.hash,
    required this.parents,
    required this.authorName,
    required this.authorEmail,
    required this.authorDate,
    required this.refs,
    required this.subject,
  });

  bool get isMerge => parents.length > 1;
  String get shortHash => hash.length >= 7 ? hash.substring(0, 7) : hash;
}

/// Parses the NUL-separated log stream into commit records.
List<CommitRecord> parseLogZ(String zOutput) {
  final records = <CommitRecord>[];
  for (final token in zOutput.split('\x00')) {
    // Git may emit a trailing newline after the last record.
    final t = token.startsWith('\n') ? token.substring(1) : token;
    if (t.isEmpty) continue;
    final f = t.split('\x1f');
    if (f.length < 7) continue; // malformed — skip defensively
    records.add(CommitRecord(
      hash: f[0],
      parents: f[1].isEmpty ? const [] : f[1].split(' '),
      authorName: f[2],
      authorEmail: f[3],
      authorDate: DateTime.fromMillisecondsSinceEpoch(
          (int.tryParse(f[4]) ?? 0) * 1000),
      refs: parseDecorations(f[5]),
      subject: f.sublist(6).join('\x1f'), // subject can't contain 0x1f, but be safe
    ));
  }
  return records;
}

/// Parses a `%D` decoration string produced with `--decorate=full`,
/// e.g. `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0`.
List<RefName> parseDecorations(String decoration) {
  if (decoration.isEmpty) return const [];
  final refs = <RefName>[];
  for (final raw in decoration.split(', ')) {
    var part = raw.trim();
    if (part.isEmpty) continue;
    var isCurrent = false;
    if (part.startsWith('HEAD -> ')) {
      isCurrent = true;
      part = part.substring('HEAD -> '.length);
    } else if (part == 'HEAD') {
      refs.add(const RefName('HEAD', RefKind.head));
      continue;
    }
    if (part.startsWith('tag: ')) {
      part = part.substring('tag: '.length);
    }
    if (part.startsWith('refs/heads/')) {
      refs.add(RefName(part.substring('refs/heads/'.length),
          RefKind.localBranch,
          isCurrent: isCurrent));
    } else if (part.startsWith('refs/remotes/')) {
      refs.add(RefName(
          part.substring('refs/remotes/'.length), RefKind.remoteBranch));
    } else if (part.startsWith('refs/tags/')) {
      refs.add(RefName(part.substring('refs/tags/'.length), RefKind.tag));
    } else {
      refs.add(RefName(part, RefKind.other, isCurrent: isCurrent));
    }
  }
  return refs;
}
