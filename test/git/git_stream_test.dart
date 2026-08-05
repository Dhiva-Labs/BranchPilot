import 'dart:io';

import 'package:branch_pilot/git/git_cli.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> split(List<String> chunks) =>
      Stream.fromIterable(chunks).transform(const ProgressLineSplitter()).toList();

  group('ProgressLineSplitter', () {
    test('splits on newlines', () async {
      expect(await split(['a\nb\nc\n']), ['a', 'b', 'c']);
    });

    test('splits on carriage returns (git progress rewrites)', () async {
      expect(
        await split(['Receiving objects:  10%\rReceiving objects: 100%\rdone\n']),
        ['Receiving objects:  10%', 'Receiving objects: 100%', 'done'],
      );
    });

    test('handles chunks broken mid-line and \\r\\n pairs', () async {
      expect(await split(['par', 'tial\r\nnext', ' line\n']),
          ['partial', 'next line']);
    });

    test('emits trailing unterminated content at stream end', () async {
      expect(await split(['no newline at end']), ['no newline at end']);
    });

    test('drops empty lines', () async {
      expect(await split(['\n\r\na\n\n']), ['a']);
    });
  });

  test('GitCli.start streams output and exit code', () async {
    final tmp = await Directory.systemTemp.createTemp('branchpilot_stream_');
    addTearDown(() => tmp.delete(recursive: true));
    final proc = await GitCli(tmp.path).start(['--version']);
    final out = await proc.stdoutLines.toList();
    expect(await proc.exitCode, 0);
    expect(out.single, startsWith('git version'));
  });
}
