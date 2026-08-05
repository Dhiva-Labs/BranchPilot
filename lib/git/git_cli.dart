import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Thrown when a git command exits non-zero (and the caller asked for a check).
class GitException implements Exception {
  final String command;
  final int exitCode;
  final String stderr;

  GitException(this.command, this.exitCode, this.stderr);

  @override
  String toString() =>
      'git $command exited $exitCode${stderr.isEmpty ? '' : ': ${stderr.trim()}'}';
}

class GitResult {
  final int exitCode;
  final List<int> stdoutBytes;
  final String stderr;

  GitResult(this.exitCode, this.stdoutBytes, this.stderr);

  String get stdout => utf8.decode(stdoutBytes, allowMalformed: true);
}

/// A running git process with live line streams (see [GitCli.start]).
class GitProcess {
  final Process _process;

  /// The argv (minus the global flags), for task labels and errors.
  final String command;

  /// stdout/stderr as lines. Git writes progress updates ("Receiving
  /// objects:  42% …") terminated by carriage returns, so lines are split on
  /// both `\r` and `\n`. Single-subscription — listen immediately.
  final Stream<String> stdoutLines;
  final Stream<String> stderrLines;

  GitProcess._(this._process, this.command, this.stdoutLines, this.stderrLines);

  Future<int> get exitCode => _process.exitCode;

  void kill() => _process.kill();
}

/// Splits a character stream into lines on `\n` OR `\r` (git progress
/// rewrites lines with bare carriage returns). Empty lines are dropped; a
/// trailing unterminated chunk is emitted at stream end.
class ProgressLineSplitter extends StreamTransformerBase<String, String> {
  const ProgressLineSplitter();

  @override
  Stream<String> bind(Stream<String> stream) async* {
    var buffer = '';
    await for (final chunk in stream) {
      buffer += chunk;
      var start = 0;
      for (var i = 0; i < buffer.length; i++) {
        final c = buffer.codeUnitAt(i);
        if (c == 0x0A || c == 0x0D) {
          if (i > start) yield buffer.substring(start, i);
          start = i + 1;
        }
      }
      buffer = buffer.substring(start);
    }
    if (buffer.isNotEmpty) yield buffer;
  }
}

/// The single chokepoint for git invocations: `git -C <repo> <args>` with
/// pager and colour forced off. Nothing else in the app calls Process for git.
class GitCli {
  final String repoPath;

  const GitCli(this.repoPath);

  /// Resolved once: prefer the system git over whatever is first on PATH.
  /// When running under the Flutter snap (dev runs, `flutter test`), the
  /// snap's own ancient git (2.25) shadows the system one.
  static final String gitExecutable =
      File('/usr/bin/git').existsSync() ? '/usr/bin/git' : 'git';

  /// Child environment for every git process. Built from the parent
  /// environment, minus the git variables the Flutter snap exports for its
  /// bundled git 2.25 (GIT_EXEC_PATH etc.): a mixed pipeline — system git
  /// front-end, snap helper binaries — fails outright on the changed
  /// GIT_CONFIG_PARAMETERS quoting. Only applies when actually running
  /// inside the flutter snap; production launches are untouched.
  static final Map<String, String> _baseEnv = _buildBaseEnv();

  static Map<String, String> _buildBaseEnv() {
    final env = Map<String, String>.of(Platform.environment);
    if (env['SNAP_INSTANCE_NAME'] == 'flutter') {
      env.remove('GIT_EXEC_PATH');
      env.remove('GIT_CONFIG_NOSYSTEM');
      env.remove('GIT_EDITOR');
      env.remove('GIT_SSL_CAINFO');
      final path = env['PATH'];
      if (path != null) {
        env['PATH'] = path
            .split(':')
            .where((e) => !e.contains('/snap/flutter/'))
            .join(':');
      }
    }
    // Don't take optional locks for read commands (status), so we never fight
    // a git process the user runs in a terminal at the same time.
    env['GIT_OPTIONAL_LOCKS'] = '0';
    env['LC_ALL'] = 'C.UTF-8';
    return env;
  }

  List<String> _argv(List<String> args) => [
        '--no-pager',
        '-c', 'color.ui=false',
        '-C', repoPath,
        ...args,
      ];

  /// Runs git to completion. Throws [GitException] on non-zero exit unless
  /// [check] is false.
  Future<GitResult> run(
    List<String> args, {
    bool check = true,
    List<int>? stdin,
    Map<String, String>? environment,
  }) async {
    final Process proc;
    try {
      proc = await Process.start(gitExecutable, _argv(args),
          environment: {..._baseEnv, ...?environment},
          includeParentEnvironment: false);
    } on ProcessException catch (e) {
      throw GitException(args.join(' '), -1, 'could not start git: ${e.message}');
    }
    try {
      if (stdin != null) proc.stdin.add(stdin);
      await proc.stdin.close();
    } catch (_) {
      // The command may exit without reading stdin; ignore the broken pipe.
    }
    final stdoutBytes = <int>[];
    final stderrBuf = StringBuffer();
    final outDone = proc.stdout.forEach(stdoutBytes.addAll);
    final errDone = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(stderrBuf.write);
    final exitCode = await proc.exitCode;
    await outDone;
    await errDone;
    final result = GitResult(exitCode, stdoutBytes, stderrBuf.toString());
    if (check && exitCode != 0) {
      throw GitException(args.join(' '), exitCode, result.stderr);
    }
    return result;
  }

  /// Starts a long-running git command (fetch/pull/push) with line-streamed
  /// output for progress rendering. Unlike [run], the caller owns the
  /// lifecycle: listen to the streams promptly (single-subscription) and
  /// await [GitProcess.exitCode].
  Future<GitProcess> start(
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    final Process proc;
    try {
      proc = await Process.start(gitExecutable, _argv(args),
          environment: {..._baseEnv, ...?environment},
          includeParentEnvironment: false);
    } on ProcessException catch (e) {
      throw GitException(args.join(' '), -1, 'could not start git: ${e.message}');
    }
    try {
      await proc.stdin.close();
    } catch (_) {}
    Stream<String> lines(Stream<List<int>> s) => s
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const ProgressLineSplitter());
    return GitProcess._(
        proc, args.join(' '), lines(proc.stdout), lines(proc.stderr));
  }

  /// Resolves [dir] to the repository's top-level working directory, or null
  /// if it is not inside a git work tree.
  static Future<String?> discoverToplevel(String dir) async {
    try {
      final r = await GitCli(dir).run(['rev-parse', '--show-toplevel']);
      final top = r.stdout.trim();
      return top.isEmpty ? null : top;
    } on GitException {
      return null;
    }
  }
}
