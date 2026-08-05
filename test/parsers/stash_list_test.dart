import 'package:branch_pilot/git/parsers/stash_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseStashListZ', () {
    test('parses multiple entries with indices and messages', () {
      final raw = [
        'stash@{0}\x1fWIP on main: 1234567 message one',
        'stash@{1}\x1fOn feature: custom message',
      ].join('\x00');
      final items = parseStashListZ(raw);
      expect(items, hasLength(2));
      expect(items[0].index, 0);
      expect(items[0].rawRef, 'stash@{0}');
      expect(items[0].message, 'WIP on main: 1234567 message one');
      expect(items[1].index, 1);
      expect(items[1].rawRef, 'stash@{1}');
      expect(items[1].message, 'On feature: custom message');
    });

    test('trailing NUL after the last record is ignored (as `-z` always emits)',
        () {
      final raw = 'stash@{0}\x1fOn main: msg\x00';
      final items = parseStashListZ(raw);
      expect(items, hasLength(1));
      expect(items.single.index, 0);
      expect(items.single.message, 'On main: msg');
    });

    test('empty input yields no stashes', () {
      expect(parseStashListZ(''), isEmpty);
      expect(parseStashListZ('\x00'), isEmpty);
    });

    test('a message containing further colons/spaces stays intact', () {
      final raw = 'stash@{2}\x1fOn main: fix: something with: colons';
      final items = parseStashListZ(raw);
      expect(items.single.message, 'On main: fix: something with: colons');
      expect(items.single.index, 2);
    });

    test('a malformed record without the 0x1f separator is skipped', () {
      final raw =
          ['no-separator-here', 'stash@{0}\x1fOn main: msg'].join('\x00');
      final items = parseStashListZ(raw);
      expect(items, hasLength(1));
      expect(items.single.rawRef, 'stash@{0}');
    });

    test('double-digit index parses correctly', () {
      final items = parseStashListZ('stash@{12}\x1fOn main: old stash');
      expect(items.single.index, 12);
    });
  });
}
