import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lootlog/data/actions.dart';
import 'package:lootlog/data/db/database.dart';
import 'package:lootlog/data/providers.dart';
import 'package:lootlog/features/setup/setup_screen.dart';

void main() {
  testWidgets('a failing finish shows an error instead of doing nothing',
      (tester) async {
    // A closed database makes every DB call throw — the same shape of failure
    // Android users hit when sqlite could not load.
    final db = AppDatabase(NativeDatabase.memory());
    await db.close();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          deviceIdProvider.overrideWithValue('test-device'),
        ],
        child: const MaterialApp(
          home: SetupScreen(debugJumpToSummary: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Begin the adventure'));
    await tester.pumpAndSettle();

    // The screen is still up and a visible error is shown.
    expect(find.textContaining('Could not save'), findsOneWidget);
  });
}
