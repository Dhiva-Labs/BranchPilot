import 'package:flutter/material.dart';

import '../../git/parsers/unified_diff.dart';
import 'syntax.dart';

/// Above this many total lines in a file's diff, syntax highlighting is
/// skipped — re_highlight is not free, and a huge generated-file diff should
/// still open promptly.
const int _kHighlightLineBudget = 3000;

/// Read-only-by-default renderer for a list of parsed file diffs: binary /
/// no-textual-changes notes, and hunk cards with gutters + tinted
/// syntax-highlighted lines.
///
/// Used both by the staging [DiffView] (hunk actions wired to stage/unstage
/// buttons via [hunkAction]) and by the commit-detail panel (`hunkAction:
/// null` — historical diffs are read-only).
///
/// Deliberately not scrollable itself (a plain [Column]) so callers can embed
/// it either inside their own [ListView] (the staging diff view) or inline
/// inside another list without nesting scrollables (an expanded file row in
/// the commit-detail panel).
class HunksView extends StatelessWidget {
  final List<FileDiff> files;

  /// Builds the trailing header button for one hunk; null → no button
  /// (read-only mode).
  final Widget Function(FileDiff file, DiffHunk hunk)? hunkAction;

  const HunksView({super.key, required this.files, this.hunkAction});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final file in files) ..._fileSection(file),
      ],
    );
  }

  List<Widget> _fileSection(FileDiff file) {
    if (file.isBinary) {
      return const [_CenteredNote('Binary file')];
    }
    if (file.hunks.isEmpty) {
      return const [_CenteredNote('No textual changes')];
    }
    final totalLines = file.hunks.fold<int>(0, (a, h) => a + h.lines.length);
    final language =
        totalLines > _kHighlightLineBudget ? null : languageOf(file.path);
    return [
      for (final hunk in file.hunks)
        _HunkCard(
          hunk: hunk,
          language: language,
          action: hunkAction?.call(file, hunk),
        ),
    ];
  }
}

class _CenteredNote extends StatelessWidget {
  final String text;

  const _CenteredNote(this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(text,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
      ),
    );
  }
}

class _HunkCard extends StatelessWidget {
  final DiffHunk hunk;
  final String? language;
  final Widget? action;

  const _HunkCard({required this.hunk, required this.language, this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    hunk.header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant),
                  ),
                ),
                ?action,
              ],
            ),
          ),
          for (final line in hunk.lines)
            _LineRow(line: line, language: language),
        ],
      ),
    );
  }
}

const _kGutterWidth = 40.0;
const _kMarkerWidth = 14.0;
const _kContentStyle =
    TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.4);

class _LineRow extends StatelessWidget {
  final DiffLine line;
  final String? language;

  const _LineRow({required this.line, required this.language});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (line.kind == DiffLineKind.noNewline) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(width: _kGutterWidth),
            const SizedBox(width: _kGutterWidth),
            const SizedBox(width: _kMarkerWidth),
            Expanded(
              child: Text(
                line.raw,
                style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    }

    final tint = switch (line.kind) {
      DiffLineKind.addition => Colors.green.withValues(alpha: 0.10),
      DiffLineKind.deletion => Colors.red.withValues(alpha: 0.10),
      _ => null,
    };
    final marker = switch (line.kind) {
      DiffLineKind.addition => '+',
      DiffLineKind.deletion => '-',
      _ => '',
    };
    final markerColor = switch (line.kind) {
      DiffLineKind.addition => Colors.greenAccent,
      DiffLineKind.deletion => Colors.redAccent,
      _ => scheme.onSurfaceVariant,
    };
    // Display only: a trailing CR (CRLF fixtures) would otherwise render as
    // a stray glyph. The raw line — CR included — is still what gets staged.
    var content = line.text;
    if (content.endsWith('\r')) {
      content = content.substring(0, content.length - 1);
    }

    return Container(
      color: tint,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _kGutterWidth,
            child: Text(
              line.oldLineNo?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
            ),
          ),
          SizedBox(
            width: _kGutterWidth,
            child: Text(
              line.newLineNo?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
            ),
          ),
          SizedBox(
            width: _kMarkerWidth,
            child: Text(marker,
                style: _kContentStyle.copyWith(
                    color: markerColor, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Text.rich(highlightLine(content, language, _kContentStyle)),
          ),
        ],
      ),
    );
  }
}
