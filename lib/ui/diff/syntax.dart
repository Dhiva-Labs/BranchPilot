/// Syntax highlighting for the diff view: maps a file path to a highlight.js
/// grammar name and renders one line of code as a themed [TextSpan].
///
/// Highlighting is a nicety, never a reason to blank out a diff — any
/// failure (unrecognised language, a parser hiccup on a strange snippet)
/// falls back to a plain, unstyled span.
library;

import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';

/// Registering every bundled grammar is real work; as a top-level `final`
/// this is lazily built on first use rather than at app startup.
final Highlight _hl = Highlight()..registerLanguages(builtinAllLanguages);

/// Extension (lowercase, no dot) → highlight.js language name. `null` means
/// "recognised, but deliberately shown as plain text".
const Map<String, String?> _extensionLanguages = {
  'dart': 'dart',
  'js': 'javascript',
  'mjs': 'javascript',
  'jsx': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'java': 'java',
  'kt': 'kotlin',
  'c': 'c',
  'h': 'c',
  'cpp': 'cpp',
  'cc': 'cpp',
  'hpp': 'cpp',
  'go': 'go',
  'rs': 'rust',
  'rb': 'ruby',
  'php': 'php',
  'swift': 'swift',
  'cs': 'csharp',
  'sh': 'bash',
  'bash': 'bash',
  'yaml': 'yaml',
  'yml': 'yaml',
  'json': 'json',
  'xml': 'xml',
  'html': 'html',
  'css': 'css',
  'scss': 'scss',
  'md': 'markdown',
  'sql': 'sql',
  'gradle': 'gradle',
  'cmake': 'cmake',
  'txt': null,
};

/// The highlight.js grammar name for [path], or null for plain text (no
/// extension, or one we don't have/want a grammar for).
String? languageOf(String path) {
  final ext = p.extension(path);
  if (ext.isEmpty) return null;
  return _extensionLanguages[ext.substring(1).toLowerCase()];
}

/// Renders one line of [code] as a themed [TextSpan]. Falls back to a plain
/// span styled with [base] when [language] is null or highlighting fails —
/// an unregistered/unknown language throws inside re_highlight.
TextSpan highlightLine(String code, String? language, TextStyle base) {
  if (language == null) return TextSpan(text: code, style: base);
  try {
    final result = _hl.highlight(code: code, language: language);
    final renderer = TextSpanRenderer(base, atomOneDarkTheme);
    result.render(renderer);
    return renderer.span ?? TextSpan(text: code, style: base);
  } catch (_) {
    return TextSpan(text: code, style: base);
  }
}
