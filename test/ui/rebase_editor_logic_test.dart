import 'package:branch_pilot/git/rebase.dart';
import 'package:branch_pilot/ui/rebase/rebase_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget-level tests for [RebaseEditorBody] — the dialog's editor content,
/// extracted so it can be pumped directly with a canned candidate list (no
/// real git, no ProviderScope: the widget itself is provider-free).
void main() {
  const aHash = '1111111aaaa000000000000000000000000000a';
  const bHash = '2222222bbbb000000000000000000000000000b';
  const cHash = '3333333cccc000000000000000000000000000c';
  final shortA = aHash.substring(0, 7);
  final shortB = bHash.substring(0, 7);
  final shortC = cHash.substring(0, 7);

  RebaseTodoEntry entry(String hash, String subject) =>
      RebaseTodoEntry(hash: hash, subject: subject);

  // Oldest-first (todo order), as rebaseCandidatesProvider returns it.
  List<RebaseTodoEntry> threeEntries() =>
      [entry(aHash, 'A'), entry(bHash, 'B'), entry(cHash, 'C')];

  Future<void> pumpBody(
    WidgetTester tester, {
    required List<RebaseTodoEntry> entries,
    required void Function(RebasePlan plan) onStart,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF4C8DFF),
              brightness: Brightness.dark)),
      home: Scaffold(
        body: RebaseEditorBody(
          baseHash: 'base',
          initialEntries: entries,
          onStart: onStart,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  DropdownButton<RebaseAction> actionDropdown(
          WidgetTester tester, String shortHash) =>
      tester.widget<DropdownButton<RebaseAction>>(
          find.byKey(Key('rebase-action-$shortHash')));

  testWidgets('initial display order is newest-first (reverse of todo order)',
      (tester) async {
    await pumpBody(tester, entries: threeEntries(), onStart: (_) {});

    // ReorderableListView (this Flutter version) doesn't expose its
    // constructed children list directly — it's folded into itemBuilder /
    // itemCount — so rebuild each item from those to inspect its key.
    final finder = find.byType(ReorderableListView);
    final list = tester.widget<ReorderableListView>(finder);
    final ctx = tester.element(finder);
    final keys = [
      for (var i = 0; i < list.itemCount; i++) list.itemBuilder(ctx, i).key
    ];
    expect(keys,
        [const ValueKey(cHash), const ValueKey(bHash), const ValueKey(aHash)]);

    // Newest (C) sits above B, which sits above the oldest (A).
    expect(tester.getTopLeft(find.text('C')).dy,
        lessThan(tester.getTopLeft(find.text('B')).dy));
    expect(tester.getTopLeft(find.text('B')).dy,
        lessThan(tester.getTopLeft(find.text('A')).dy));
  });

  testWidgets(
      'squash selected on the first-kept commit shows the validatePlan '
      'error and disables Start', (tester) async {
    await pumpBody(tester, entries: threeEntries(), onStart: (_) {});

    // A is the oldest (first in todo order) — nothing precedes it, so
    // squash is invalid regardless of the other two rows' actions.
    actionDropdown(tester, shortA).onChanged!(RebaseAction.squash);
    await tester.pumpAndSettle();

    expect(find.textContaining('cannot be a squash/fixup'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('rebase-start')))
            .onPressed,
        isNull);
  });

  testWidgets(
      'dropping every commit shows the "everything dropped" error and '
      'disables Start', (tester) async {
    await pumpBody(tester, entries: threeEntries(), onStart: (_) {});

    for (final short in [shortA, shortB, shortC]) {
      actionDropdown(tester, short).onChanged!(RebaseAction.drop);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.textContaining('discard all of them'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('rebase-start')))
            .onPressed,
        isNull);
  });

  testWidgets(
      'reword stores the message and the start callback receives an '
      'oldest-first plan', (tester) async {
    RebasePlan? captured;
    await pumpBody(tester,
        entries: threeEntries(), onStart: (plan) => captured = plan);

    actionDropdown(tester, shortA).onChanged!(RebaseAction.reword);
    await tester.pumpAndSettle();

    // Prefilled with the original subject (TextField renders via
    // EditableText, so check the controller directly rather than
    // find.textContaining).
    final rewordField =
        tester.widget<TextField>(find.byKey(const Key('reword-field')));
    expect(rewordField.controller!.text, 'A');
    await tester.enterText(
        find.byKey(const Key('reword-field')), 'A reworded');
    await tester.tap(find.byKey(const Key('reword-save')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rebase-start')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.entries.map((e) => e.hash), [aHash, bHash, cHash]);
    expect(captured!.entries[0].action, RebaseAction.reword);
    expect(captured!.entries[0].newMessage, 'A reworded');
    // Untouched entries keep their default pick action.
    expect(captured!.entries[1].action, RebaseAction.pick);
    expect(captured!.entries[2].action, RebaseAction.pick);
  });

  testWidgets('cancelling the reword dialog keeps the previous action',
      (tester) async {
    await pumpBody(tester, entries: threeEntries(), onStart: (_) {});

    actionDropdown(tester, shortA).onChanged!(RebaseAction.reword);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(actionDropdown(tester, shortA).value, RebaseAction.pick);
  });

  testWidgets(
      'reordering via ReorderableListView.onReorderItem updates the built '
      'plan', (tester) async {
    RebasePlan? captured;
    await pumpBody(tester,
        entries: threeEntries(), onStart: (plan) => captured = plan);

    // Display order is [C, B, A] (newest-first). onReorderItem's newIndex
    // (unlike the deprecated onReorder) is already adjusted for the
    // removal, so moving index 0 (C) to index 2 means: remove C leaving
    // [B, A], then insert C at index 2 → [B, A, C]. The plan (its reverse,
    // oldest-first) is [C, A, B]: C now applies first; A and B keep their
    // relative order.
    final list =
        tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list.onReorderItem!(0, 2);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rebase-start')));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.entries.map((e) => e.hash), [cHash, aHash, bHash]);
  });
}
