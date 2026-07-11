# Critical Bugs Fix Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the six release-blocking defects in `docs/superpowers/specs/2026-07-10-critical-bugs-design.md`: Android database initialization, silent setup failure, missing QR scan in the join flow, mislabelled member edits in the activity feed, custom member sprites not rendering, and the broken desktop tutorial.

**Architecture:** LootLog is a local-first, event-sourced Flutter app. All money state derives from `lib/domain/reducer.dart`; the fixes here touch only data-layer bootstrap, feature UI, projections (activity feed), and the game adapter — **no reducer changes**. The activity feed and game adapter are pure functions over events/state and get TDD.

**Tech Stack:** Flutter stable, Riverpod (codegen), drift (via package:sqlite3 native-assets hook), mobile_scanner, qr_flutter.

## Global Constraints

- Money is integer cents everywhere; nothing in this plan touches money math.
- Never UPDATE/DELETE domain rows; the member-editor fix *avoids appending* a redundant event, which is allowed (it never mutates existing ones).
- `./check.sh` (dart analyze + flutter test) must pass before every commit. Run it from the repo root (it operates on `app/`).
- Conventional commits, one commit per completed task.
- Working directory for all `flutter` commands: `app/`.
- The word "slice" never appears in UI copy. Classic-mode copy avoids Adventure jargon.
- Android-only device steps are listed as a manual checklist at the end; do not block commits on them, but do not claim the corresponding acceptance criteria are verified until they run.

---

### Task 1: Android sqlite binary (root cause of sync + setup-hang)

**Files:**
- Modify: `app/pubspec.yaml:72-82` (the `hooks:` block and its comment)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a working database on Android; later tasks assume DB calls can succeed on-device.

**Background for the implementer:** package:sqlite3 ≥3.x builds a "code asset" via a build hook. `source: system` means `dlopen('libsqlite3.so')` at runtime — fine on Windows/macOS/Linux, impossible on Android (the OS's libsqlite3.so is private since Android 7). The default `source: sqlite3` downloads a hash-verified precompiled library per target at **build** time and bundles it. User-defines are global (cannot vary per OS), so all platforms switch to the precompiled binary — an improvement anyway, since every device then runs the identical sqlite version.

- [ ] **Step 1: Replace the hooks block in `app/pubspec.yaml`**

Replace lines 72–82 (the comment + `hooks:` block) with:

```yaml
# Native-asset build hooks (drift pulls in package:sqlite3, which builds a code
# asset). Use the package default: a hash-verified precompiled SQLite fetched at
# BUILD time and bundled with the app, identical on every platform.
# `source: system` is NOT usable here even though desktops ship a sqlite3:
# Android forbids apps from dlopen-ing the platform's private libsqlite3.so,
# which made every database call fail on phones (sqlite3_initialize lookup
# errors). The precompiled Android binaries are 16KB-page-aligned as required
# on Android 15+. No runtime network use — the fetch happens on the build
# machine only.
hooks:
  user_defines:
    sqlite3:
      source: sqlite3
```

- [ ] **Step 2: Rebuild and run the full test suite (this exercises the new binary on Windows)**

Run (from `app/`): `flutter pub get && flutter test`
Expected: pub get succeeds; the first test run downloads the precompiled sqlite3 for Windows; all existing tests PASS (drift tests now run against the bundled binary instead of winsqlite3.dll).

- [ ] **Step 3: Build the Android APK if the toolchain is available**

Run (from `app/`): `flutter build apk --debug`
Expected: BUILD SUCCESSFUL. If no Android SDK is on this machine, note it and rely on the manual device checklist.

- [ ] **Step 4: Run `./check.sh` and commit**

```bash
./check.sh
git add app/pubspec.yaml
git commit -m "fix(data): bundle precompiled sqlite3 so the database opens on Android

source: system dlopens the OS libsqlite3, which Android forbids for apps;
every DB call on phones failed with sqlite3_initialize lookup errors. The
package-default precompiled binary is fetched (hash-verified) at build time,
is 16KB-page-aligned for Android 15+, and unifies the sqlite version across
all platforms."
```

---

### Task 2: Surface setup-finish failures ("Begin the adventure" dead button)

**Files:**
- Modify: `app/lib/features/setup/setup_screen.dart` (`_SetupScreenState`: `_finish()` at lines 210–230, `_bottomBar()` at lines 129–156, state fields near line 53, and the `SetupScreen` constructor at line 43)
- Test: `app/test/features/setup_finish_error_test.dart` (create)

**Interfaces:**
- Consumes: `appDatabaseProvider`, `deviceIdProvider` from `app/lib/data/providers.dart` (both exist; check their exact types there before writing overrides).
- Produces: nothing other tasks rely on.

**Background:** `_finish()` is `try { … } finally { … }` with **no catch**. A DB failure (e.g. Task 1's bug) becomes an unhandled async error; `finally` resets `_busy` and the button silently does nothing. This violates the project's "failures are silent-but-visible" invariant.

- [ ] **Step 1: Add a test seam and write the failing widget test**

First add a test-only constructor flag to `SetupScreen` (needed because `_Step` is private and driving the whole wizard through forms is brittle):

```dart
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key, this.debugJumpToSummary = false});

  /// Test-only: start at the summary step so the finish path is reachable
  /// without driving every wizard form.
  @visibleForTesting
  final bool debugJumpToSummary;

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}
```

and in `_SetupScreenState.initState()` after the existing listener line:

```dart
    if (widget.debugJumpToSummary) _index = _Step.summary.index;
```

(`@visibleForTesting` needs `import 'package:flutter/foundation.dart';` if not already imported via material.)

Then create `app/test/features/setup_finish_error_test.dart`:

```dart
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
```

Adaptation notes for the implementer: check `deviceIdProvider`'s type in `app/lib/data/providers.dart` — if it is not a plain `Provider<String>`, use the matching override form. If the summary step requires controller state to build, seed the minimal `SetupController` state the same way the wizard's party step would (see `app/lib/features/setup/setup_controller.dart`) — but only if the bare summary build throws; an error *rendered by the new catch* is exactly what we're testing, so a `buildInput()` throw caught and displayed also passes the spirit of the test.

- [ ] **Step 2: Run the test to verify it fails**

Run (from `app/`): `flutter test test/features/setup_finish_error_test.dart`
Expected: FAIL — currently there is no catch, so the tap produces an unhandled exception (the test harness reports it) and no 'Could not save' text appears.

- [ ] **Step 3: Implement the catch + visible error**

In `_SetupScreenState` add a field next to `_busy`:

```dart
  String? _finishError;
```

Replace `_finish()` with:

```dart
  Future<void> _finish() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _finishError = null;
    });
    try {
      final input = _c.buildInput();
      final db = ref.read(appDatabaseProvider);
      final plan = buildOnboardingEvents(
        input,
        deviceId: ref.read(deviceIdProvider),
        startMonth: Month.fromInstant(DateTime.now().toUtc()),
      );
      await db.eventsDao.appendEvents(plan.events);
      await ref.read(appSkinProvider.notifier).select(_c.mode);
      if (mounted) await _celebrate();
      // Saving the local setup flips isSetUpProvider and the router hands off
      // to the main shell.
      await db.localSetupDao.save(plan.localSetup);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _finishError = 'Could not save your setup: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
```

In `_bottomBar()`, show the error above the buttons — replace the current `return Padding(…)` body with:

```dart
  Widget _bottomBar() {
    final isSummary = _step == _Step.summary;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_finishError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(
                _finishError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _back,
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: !_canAdvance || _busy
                      ? null
                      : isSummary
                          ? _finish
                          : _next,
                  child: Text(isSummary ? 'Begin the adventure' : 'Next'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run (from `app/`): `flutter test test/features/setup_finish_error_test.dart`
Expected: PASS

- [ ] **Step 5: Run `./check.sh` and commit**

```bash
./check.sh
git add app/lib/features/setup/setup_screen.dart app/test/features/setup_finish_error_test.dart
git commit -m "fix(setup): surface finish failures instead of a silent dead button

_finish had try/finally with no catch, so any database error during
'Begin the adventure' vanished as an unhandled async error and the wizard
appeared frozen. Failures now render inline above the wizard buttons."
```

---

### Task 3: QR scanning in "Join an existing party"

**Files:**
- Create: `app/lib/features/sync/pairing_qr.dart`
- Modify: `app/lib/features/sync/sync_hubs_screen.dart` (lines 233–254 `_canScanQr`/`_scanAndPair`, lines 532–564 `_ScanPairingQrScreen` — replace with the shared versions)
- Modify: `app/lib/features/setup/join_party_screen.dart`
- Test: `app/test/features/pairing_qr_test.dart` (create)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `PairingQrPayload {String url, String pairingSecret}`, `PairingQrPayload? parsePairingQr(String raw)`, `bool get canScanPairingQr`, `class ScanPairingQrScreen extends StatefulWidget` (pushed via `Navigator.push<String>`, pops with the raw scanned string). Task-internal only, but the sync screen keeps using them.

**Background:** A camera scanner and payload parsing already exist, but as private members of the Sync & hubs screen only. The join flow — the place a brand-new phone actually starts — has manual fields only. Extract, share, wire in.

- [ ] **Step 1: Write the failing parser tests**

Create `app/test/features/pairing_qr_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lootlog/features/sync/pairing_qr.dart';

void main() {
  test('parses a valid pairing payload', () {
    final p = parsePairingQr(
        '{"url":"http://192.168.1.20:8787","pairingSecret":"abc123"}');
    expect(p, isNotNull);
    expect(p!.url, 'http://192.168.1.20:8787');
    expect(p.pairingSecret, 'abc123');
  });

  test('rejects non-JSON', () {
    expect(parsePairingQr('WIFI:S:MyNetwork;;'), isNull);
  });

  test('rejects JSON that is not an object', () {
    expect(parsePairingQr('[1,2,3]'), isNull);
  });

  test('rejects missing or non-string fields', () {
    expect(parsePairingQr('{"url":"http://x"}'), isNull);
    expect(parsePairingQr('{"pairingSecret":"s"}'), isNull);
    expect(parsePairingQr('{"url":7,"pairingSecret":"s"}'), isNull);
  });

  test('rejects empty fields', () {
    expect(parsePairingQr('{"url":"","pairingSecret":"s"}'), isNull);
    expect(parsePairingQr('{"url":"http://x","pairingSecret":""}'), isNull);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `app/`): `flutter test test/features/pairing_qr_test.dart`
Expected: FAIL — `pairing_qr.dart` does not exist yet ("Error when reading … pairing_qr.dart").

- [ ] **Step 3: Create the shared pairing-QR module**

Create `app/lib/features/sync/pairing_qr.dart`:

```dart
/// Shared hub-pairing QR helpers: the `{url, pairingSecret}` payload parser
/// and the full-screen camera scanner. Used by both the Sync & hubs screen and
/// first-run "Join an existing party".
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Whether this build can scan a pairing QR with the camera. Android only;
/// the desktop side is the one showing the code.
bool get canScanPairingQr => !kIsWeb && Platform.isAndroid;

/// The decoded `{url, pairingSecret}` payload of a hub pairing QR.
class PairingQrPayload {
  const PairingQrPayload({required this.url, required this.pairingSecret});

  final String url;
  final String pairingSecret;
}

/// Parses a scanned string; null when it isn't a LootLog pairing code.
PairingQrPayload? parsePairingQr(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final url = decoded['url'];
  final secret = decoded['pairingSecret'];
  if (url is! String || secret is! String) return null;
  if (url.isEmpty || secret.isEmpty) return null;
  return PairingQrPayload(url: url, pairingSecret: secret);
}

/// A full-screen camera scanner for the hub pairing QR. Pops with the raw
/// payload string on the first detected code. Android only (guard with
/// [canScanPairingQr]); fully on-device, no network involved.
class ScanPairingQrScreen extends StatefulWidget {
  const ScanPairingQrScreen({super.key});

  @override
  State<ScanPairingQrScreen> createState() => _ScanPairingQrScreenState();
}

class _ScanPairingQrScreenState extends State<ScanPairingQrScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the hub\'s QR code')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final code in capture.barcodes) {
            final value = code.rawValue;
            if (value != null && value.isNotEmpty) {
              _done = true;
              Navigator.of(context).pop(value);
              return;
            }
          }
        },
      ),
    );
  }
}
```

- [ ] **Step 4: Run the parser tests to verify they pass**

Run (from `app/`): `flutter test test/features/pairing_qr_test.dart`
Expected: PASS (5 tests)

- [ ] **Step 5: Point the Sync & hubs screen at the shared module**

In `app/lib/features/sync/sync_hubs_screen.dart`:
1. Add `import 'pairing_qr.dart';`.
2. Delete the private `_ScanPairingQrScreen` classes (lines ~532–564).
3. Replace the `_canScanQr` getter body with `canScanPairingQr` (or delete the getter and use `canScanPairingQr` at its call sites).
4. Rewrite `_scanAndPair` to use the shared parser:

```dart
  Future<void> _scanAndPair(SyncService service) async {
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanPairingQrScreen()),
    );
    if (payload == null || !mounted) return;
    final parsed = parsePairingQr(payload);
    if (parsed == null) {
      _snack("That QR code isn't a LootLog pairing code.");
      return;
    }
    await _pair(service, parsed.url, parsed.pairingSecret);
  }
```

5. Remove now-unused imports if the analyzer flags them (`dart:convert`, `mobile_scanner`, possibly `dart:io`/`foundation` — keep whatever is still used elsewhere in the file).

- [ ] **Step 6: Add the scan button to the join screen**

In `app/lib/features/setup/join_party_screen.dart`:
1. Add `import '../sync/pairing_qr.dart';`.
2. Add a scan handler to `_JoinPartyScreenState`:

```dart
  Future<void> _scan() async {
    final payload = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanPairingQrScreen()),
    );
    if (payload == null || !mounted) return;
    final parsed = parsePairingQr(payload);
    if (parsed == null) {
      setState(() => _error = "That QR code isn't a LootLog pairing code.");
      return;
    }
    setState(() {
      _url.text = parsed.url;
      _secret.text = parsed.pairingSecret;
      _error = null;
    });
    if (_deviceName.text.trim().isNotEmpty) {
      await _pair();
    } else {
      setState(() =>
          _error = 'Scanned! Now give this device a name and tap Pair & sync.');
    }
  }
```

3. In `_pairStep()`, directly above the existing `FilledButton.icon` (the 'Pair & sync' button), insert:

```dart
        if (canScanPairingQr) ...[
          FilledButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan the hub\'s QR code'),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
```

4. Update the intro copy (first `Text` in `_pairStep`) to:

```dart
        const Text(
          'On the hosting device (a desktop running a hub), open Sync & hubs. '
          'Scan its QR code — or read off its address and pairing secret and '
          'enter them here.',
        ),
```

- [ ] **Step 7: Run `./check.sh` and commit**

```bash
./check.sh
git add app/lib/features/sync/pairing_qr.dart app/lib/features/sync/sync_hubs_screen.dart app/lib/features/setup/join_party_screen.dart app/test/features/pairing_qr_test.dart
git commit -m "feat(setup): QR scan in Join an existing party

Extracts the pairing-QR scanner and payload parser (previously private to
the Sync & hubs screen) into a shared module and wires a scan button into
the first-run join flow, so a new phone never types the pairing secret."
```

---

### Task 4: Activity feed distinguishes member adds, edits, and portrait changes

**Files:**
- Modify: `app/lib/features/activity/activity_model.dart` (the `case MemberSet():` arm, lines 259–269)
- Test: `app/test/features/activity_model_test.dart` (extend if it exists, create otherwise)

**Interfaces:**
- Consumes: `MemberSet` event fields from `app/lib/domain/event.dart` (`memberId`, `name`, `role`, `active`, `customSpriteSha256`, `descriptionText`); `buildActivityFeed` signature stays unchanged.
- Produces: nothing other tasks rely on.

**Background:** Every `MemberSet` with `active: true` currently renders "added … to the party". `buildActivityFeed` receives the full event log (`eventLogProvider` — the same list the reducer consumes) in append order, so first-occurrence per `memberId` is derivable inside the loop with a map. Note the feed is *rebuilt from all events on every view*, so no schema change and old logs render correctly retroactively.

- [ ] **Step 1: Write the failing tests**

In `app/test/features/activity_model_test.dart` (create the file if absent; if it exists, add this group and reuse its existing event-construction helpers instead of these local ones):

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lootlog/domain/event.dart';
import 'package:lootlog/domain/reducer.dart';
import 'package:lootlog/features/activity/activity_model.dart';

void main() {
  var counter = 0;
  MemberSet member({
    required String memberId,
    required String name,
    MemberRole role = MemberRole.adult,
    bool active = true,
    String? sprite,
    String? description,
  }) {
    counter++;
    return MemberSet(
      eventId: 'evt-${counter.toString().padLeft(4, '0')}',
      deviceId: 'dev-1',
      userId: 'u-robin',
      occurredAt: DateTime.utc(2026, 7, 1).add(Duration(minutes: counter)),
      createdAt: DateTime.utc(2026, 7, 1).add(Duration(minutes: counter)),
      memberId: memberId,
      name: name,
      role: role,
      active: active,
      customSpriteSha256: sprite,
      descriptionText: description,
    );
  }

  List<String> feedTitles(List<Event> events) {
    final state = reduce(events);
    final items = buildActivityFeed(
      state,
      events,
      userNames: const {'u-robin': 'Robin'},
      meUserId: 'u-robin',
    );
    // The feed is newest-first; reverse to chronological for easy asserts.
    return items.reversed.map((i) => i.title).toList();
  }

  group('member lines', () {
    test('first MemberSet reads as an add', () {
      final titles = feedTitles([member(memberId: 'm1', name: 'Riley')]);
      expect(titles, ['Robin added Riley to the party']);
    });

    test('a later MemberSet reads as an update, not an add', () {
      final titles = feedTitles([
        member(memberId: 'm1', name: 'Riley'),
        member(memberId: 'm1', name: 'Riley R.'),
      ]);
      expect(titles, [
        'Robin added Riley to the party',
        'Robin updated Riley R.',
      ]);
    });

    test('a sprite-only change reads as a portrait update', () {
      final titles = feedTitles([
        member(memberId: 'm1', name: 'Riley'),
        member(memberId: 'm1', name: 'Riley', sprite: 'a' * 64),
      ]);
      expect(titles, [
        'Robin added Riley to the party',
        "Robin updated Riley's portrait",
      ]);
    });

    test('deactivation reads as retirement', () {
      final titles = feedTitles([
        member(memberId: 'm1', name: 'Riley'),
        member(memberId: 'm1', name: 'Riley', active: false),
      ]);
      expect(titles, [
        'Robin added Riley to the party',
        'Robin retired Riley from the party',
      ]);
    });
  });
}
```

Adaptation notes: check `MemberSet`'s exact constructor in `app/lib/domain/event.dart` and the reducer's entry point name in `app/lib/domain/reducer.dart` (`reduce(events)` is assumed here — match whatever `adapter_test.dart` / existing domain tests call).

- [ ] **Step 2: Run the tests to verify the new cases fail**

Run (from `app/`): `flutter test test/features/activity_model_test.dart`
Expected: FAIL — the update and portrait cases assert "updated" titles but get "added Riley … to the party".

- [ ] **Step 3: Implement first-occurrence-aware member lines**

In `app/lib/features/activity/activity_model.dart`, inside `buildActivityFeed` just before the `for (final e in events)` loop, add:

```dart
  // Tracks the last MemberSet seen per member while walking the (append-
  // ordered) log, so later events read as updates rather than adds.
  final lastMemberSet = <String, MemberSet>{};
```

Replace the `case MemberSet():` arm with:

```dart
      case MemberSet():
        final prev = lastMemberSet[e.memberId];
        lastMemberSet[e.memberId] = e;
        final String title;
        if (!e.active) {
          title = '${who(e.userId)} retired ${e.name} from the party';
        } else if (prev == null) {
          title = '${who(e.userId)} added ${e.name} to the party';
        } else if (prev.customSpriteSha256 != e.customSpriteSha256 &&
            prev.name == e.name &&
            prev.role == e.role &&
            prev.active == e.active &&
            prev.descriptionText == e.descriptionText) {
          title = "${who(e.userId)} updated ${e.name}'s portrait";
        } else {
          title = '${who(e.userId)} updated ${e.name}';
        }
        item = ActivityItem(
          eventId: e.eventId,
          kind: ActivityKind.config,
          userId: e.userId,
          title: title,
          occurredAt: e.occurredAt,
          isMine: mine,
        );
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (from `app/`): `flutter test test/features/activity_model_test.dart`
Expected: PASS (all 4 new cases)

- [ ] **Step 5: Check the change-log view for the same defect**

Read `app/lib/features/ledger/change_log_model.dart` (it also narrates events). If it renders `MemberSet` with an unconditional "added" phrasing, apply the same `lastMemberSet` technique there with a matching test in its existing test file. If it doesn't mention `MemberSet`, do nothing.

- [ ] **Step 6: Run `./check.sh` and commit**

```bash
./check.sh
git add app/lib/features/activity/activity_model.dart app/test/features/activity_model_test.dart
# plus the ledger files if step 5 changed them
git commit -m "fix(activity): member edits no longer read as party additions

The feed now tracks the last MemberSet per member while walking the log:
first occurrence reads as an add, sprite-only changes as a portrait update,
and everything else as an update. Deactivation still reads as retirement."
```

---

### Task 5: Member editor appends no event on a no-op save

**Files:**
- Create: `app/lib/features/settings/member_edit_diff.dart`
- Modify: `app/lib/features/settings/members_screen.dart` (the `if (saved == true …)` block at lines 219–229)
- Test: `app/test/features/member_edit_diff_test.dart` (create)

**Interfaces:**
- Consumes: `MemberState` from `app/lib/domain/state.dart` (fields: `memberId`, `name`, `role`, `active`, `customSpriteSha256`, `descriptionText`).
- Produces: `bool memberEditChanged(MemberState existing, {required String name, required MemberRole role, required bool active, String? customSpriteSha256, String? descriptionText})`.

**Background:** Opening the member editor and saving without touching anything appends a fresh `MemberSet`, polluting the permanent audit log (the user saw phantom "added to the party" lines partly because of this). The event log is append-only — the fix is to *not append* when nothing changed.

- [ ] **Step 1: Write the failing tests**

Create `app/test/features/member_edit_diff_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lootlog/domain/state.dart';
import 'package:lootlog/features/settings/member_edit_diff.dart';

void main() {
  final existing = MemberState(
    memberId: 'm1',
    name: 'Riley',
    role: MemberRole.adult,
    active: true,
    customSpriteSha256: null,
    descriptionText: 'A brave accountant.',
  );

  test('identical values are a no-op', () {
    expect(
      memberEditChanged(
        existing,
        name: 'Riley',
        role: MemberRole.adult,
        active: true,
        customSpriteSha256: null,
        descriptionText: 'A brave accountant.',
      ),
      isFalse,
    );
  });

  test('an empty description equals a null one (the sheet round-trips it)',
      () {
    final noDesc = MemberState(
      memberId: 'm1',
      name: 'Riley',
      role: MemberRole.adult,
      active: true,
      customSpriteSha256: null,
      descriptionText: null,
    );
    expect(
      memberEditChanged(
        noDesc,
        name: 'Riley',
        role: MemberRole.adult,
        active: true,
        customSpriteSha256: null,
        descriptionText: null,
      ),
      isFalse,
    );
  });

  test('each changed field is detected', () {
    expect(
      memberEditChanged(existing,
          name: 'Riley R.',
          role: MemberRole.adult,
          active: true,
          customSpriteSha256: null,
          descriptionText: 'A brave accountant.'),
      isTrue,
    );
    expect(
      memberEditChanged(existing,
          name: 'Riley',
          role: MemberRole.dependent,
          active: true,
          customSpriteSha256: null,
          descriptionText: 'A brave accountant.'),
      isTrue,
    );
    expect(
      memberEditChanged(existing,
          name: 'Riley',
          role: MemberRole.adult,
          active: false,
          customSpriteSha256: null,
          descriptionText: 'A brave accountant.'),
      isTrue,
    );
    expect(
      memberEditChanged(existing,
          name: 'Riley',
          role: MemberRole.adult,
          active: true,
          customSpriteSha256: 'f' * 64,
          descriptionText: 'A brave accountant.'),
      isTrue,
    );
    expect(
      memberEditChanged(existing,
          name: 'Riley',
          role: MemberRole.adult,
          active: true,
          customSpriteSha256: null,
          descriptionText: 'Now a bard.'),
      isTrue,
    );
  });
}
```

Adaptation note: match `MemberState`'s actual constructor in `app/lib/domain/state.dart` (it may be const / have required-vs-optional differences).

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `app/`): `flutter test test/features/member_edit_diff_test.dart`
Expected: FAIL — `member_edit_diff.dart` does not exist.

- [ ] **Step 3: Implement the diff helper**

Create `app/lib/features/settings/member_edit_diff.dart`:

```dart
/// Pure change detection for the member editor: saving with nothing changed
/// must append no event at all (the log is permanent — no-op MemberSets are
/// noise in the household's audit trail).
library;

import '../../domain/state.dart';
import '../../domain/value_types.dart';

/// Whether the edited values differ from [existing]. Null and empty
/// descriptions are equivalent (the sheet renders null as an empty field).
bool memberEditChanged(
  MemberState existing, {
  required String name,
  required MemberRole role,
  required bool active,
  String? customSpriteSha256,
  String? descriptionText,
}) {
  String norm(String? s) => (s ?? '').trim();
  return existing.name != name ||
      existing.role != role ||
      existing.active != active ||
      existing.customSpriteSha256 != customSpriteSha256 ||
      norm(existing.descriptionText) != norm(descriptionText);
}
```

(Adjust the `MemberRole` import to wherever the enum actually lives — `domain/state.dart` or `domain/value_types.dart`; the analyzer will say.)

- [ ] **Step 4: Run the tests to verify they pass**

Run (from `app/`): `flutter test test/features/member_edit_diff_test.dart`
Expected: PASS

- [ ] **Step 5: Wire it into the editor**

In `app/lib/features/settings/members_screen.dart`, add `import 'member_edit_diff.dart';` and replace the save block (lines 219–229) with:

```dart
    if (saved == true && nameController.text.trim().isNotEmpty) {
      final name = nameController.text.trim();
      final desc = descController.text.trim();
      final description = desc.isEmpty ? null : desc;
      if (existing != null &&
          !memberEditChanged(
            existing,
            name: name,
            role: role,
            active: active,
            customSpriteSha256: spriteSha,
            descriptionText: description,
          )) {
        return; // Nothing changed — append no event.
      }
      await ref.read(householdActionsProvider)?.setMember(
            memberId: existing?.memberId,
            name: name,
            role: role,
            active: active,
            customSpriteSha256: spriteSha,
            descriptionText: description,
          );
    }
```

- [ ] **Step 6: Run `./check.sh` and commit**

```bash
./check.sh
git add app/lib/features/settings/member_edit_diff.dart app/lib/features/settings/members_screen.dart app/test/features/member_edit_diff_test.dart
git commit -m "fix(members): saving an unchanged member appends no event

Open-edit-save previously wrote a fresh MemberSet every time, filling the
permanent activity log with phantom entries."
```

---

### Task 6: Custom member sprites render in Adventure mode

**Files:**
- Modify: `app/lib/game/adapter.dart` (hero/partner sprite construction, lines 55–61)
- Modify: `app/lib/game/adventure_screen.dart` (`customSpriteBlobsProvider`, lines 26–44)
- Test: `app/test/game/adapter_test.dart` (extend)

**Interfaces:**
- Consumes: `HouseholdState.members` (`Map<String, MemberState>`, adults' `memberId` == their userId), `SpriteRef.custom(sha, label:)` / `SpriteRef.asset(name, label:)` from `app/lib/game/game_state.dart`.
- Produces: nothing other tasks rely on.

**Background (two-layer bug):** (a) the hero/partner party frames hardcode `Sprites.heroA`/`heroB` asset refs, ignoring `customSpriteSha256`; (b) even where the roster path builds a correct `SpriteRef.custom` (adapter line 201), the blob preloader only reads quest and pet blobs, so member sprite bytes never reach the resolver and `GameSprite` falls back to the initials placeholder. Both layers must be fixed for a PNG to appear.

- [ ] **Step 1: Write the failing adapter test**

In `app/test/game/adapter_test.dart`, add (reusing the file's existing fixture/builder helpers — look at how neighbouring tests build a `HouseholdState` with members, likely via `adventure_fixtures.dart`, and follow that pattern; the assertions are what matter):

```dart
  test('hero party frame uses the member custom sprite when set', () {
    // Build a state whose adult member for meUserId carries a custom sprite.
    final state = stateWithMembers([
      memberFixture(id: 'u-me', name: 'Robin', sprite: 'a' * 64),
      memberFixture(id: 'u-partner', name: 'Sam'),
    ]);
    final game = buildGameState(state,
        meUserId: 'u-me', userNames: const {'u-me': 'Robin', 'u-partner': 'Sam'});
    expect(game.hero.sprite.isCustom, isTrue);
    expect(game.hero.sprite.customSpriteSha256, 'a' * 64);
    expect(game.partner.sprite.isCustom, isFalse);
  });
```

Adaptation notes: `game.hero` / `game.partner` are placeholders — open `app/lib/game/game_state.dart` and use the real field names for the two party-frame sprites (search for where `heroSprite`/`partnerSprite` from `adapter.dart:58-61` land in the returned `GameState`). `stateWithMembers`/`memberFixture` are placeholders for whatever fixture helpers `adapter_test.dart` already uses to build states — reduce a `List<Event>` with `MemberSet` events if that's the file's idiom.

- [ ] **Step 2: Run the test to verify it fails**

Run (from `app/`): `flutter test test/game/adapter_test.dart`
Expected: FAIL — the hero sprite is an asset ref (`isCustom` false) because the adapter hardcodes `Sprites.heroA`.

- [ ] **Step 3: Implement custom-aware hero sprites in the adapter**

In `app/lib/game/adapter.dart`, replace lines 58–61:

```dart
  final heroSprite =
      _memberSprite(state, meUserId, Sprites.heroA, nameOf(meUserId) ?? 'You');
  final partnerSprite = _memberSprite(
      state, partnerId, Sprites.heroB, nameOf(partnerId) ?? 'Partner');
```

and add the helper near the file's other private helpers:

```dart
/// The party-frame sprite for a member: their uploaded custom sprite when one
/// is set, else the role's default asset.
SpriteRef _memberSprite(
    HouseholdState state, String userId, String fallbackAsset, String label) {
  final sha = state.members[userId]?.customSpriteSha256;
  return sha != null
      ? SpriteRef.custom(sha, label: label)
      : SpriteRef.asset(fallbackAsset, label: label);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run (from `app/`): `flutter test test/game/adapter_test.dart`
Expected: PASS

- [ ] **Step 5: Preload member sprite blobs**

In `app/lib/game/adventure_screen.dart`, extend the `shas` set inside `customSpriteBlobsProvider` (lines 31–36) to include members, and update the doc comment:

```dart
/// Reads every custom sprite blob the current state references (member, quest
/// & pet sprites) into an in-memory `sha256 -> bytes` map for
/// [AssetSpriteResolver]. Missing blobs are simply skipped — the sprite falls
/// back to a placeholder.
```

```dart
  final shas = <String>{
    for (final m in state.members.values)
      if (m.customSpriteSha256 != null) m.customSpriteSha256!,
    for (final q in state.quests.values)
      if (q.customSpriteSha256 != null) q.customSpriteSha256!,
    for (final p in state.pets.values)
      if (p.customSpriteSha256 != null) p.customSpriteSha256!,
  };
```

- [ ] **Step 6: Verify on the desktop app**

Run (from `app/`): `flutter run -d windows`
Switch to Adventure mode with the pixel tier active, upload a PNG on an adult member (Settings → Members), and confirm the PNG renders in the party frame and roster instead of initials. (The image renders pixelated at integer scale — that's by design.)

- [ ] **Step 7: Run `./check.sh` and commit**

```bash
./check.sh
git add app/lib/game/adapter.dart app/lib/game/adventure_screen.dart app/test/game/adapter_test.dart
git commit -m "fix(game): member custom sprites actually render in adventure mode

Two layers: the blob preloader never read member sprite bytes (only quests
and pets), and the hero party frames hardcoded the heroA/heroB assets,
ignoring customSpriteSha256 and assuming exactly two adults."
```

---

### Task 7: Desktop tutorial — resumable progress and non-broken layout

**Files:**
- Modify: `app/lib/features/tutorial/tutorial_prefs.dart` (whole file evolves from a bool to progress)
- Modify: `app/lib/features/tutorial/tutorial.dart` (`TutorialTour.show`, `_TutorialDialogState`)
- Test: `app/test/features/tutorial_prefs_test.dart` (create; check first whether a tutorial test already exists and extend it instead)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `TutorialProgress {bool completed, int stepIndex}`, `tutorialProgressProvider` replacing `tutorialSeenProvider` (update `TutorialGate`, `app/lib/features/shell/app_shell.dart:79` and `app/lib/features/settings/settings_screen.dart` if they reference the old provider).

**Background:** Today any dismissal (skip, finish, barrier-tap, or the dialog dying for an unrelated reason) marks the tour seen forever. The user saw one misshapen popup, hit Next, the dialog vanished, and the tour never returned. Spec: resume from the same step on next launch; Skip and Done complete it; replay stays available from Settings. There is also an undiagnosed "Next closes the dialog" behavior and a layout problem on desktop — reproduce first.

- [ ] **Step 1: Reproduce on Windows and diagnose (systematic-debugging)**

Run (from `app/`): `flutter run -d windows` with a cleared pref (delete `tutorial_seen.txt` from the app documents directory, or on a fresh profile). Reproduce: does the popup render misshapen? Does Next close it? Capture the console for exceptions. Candidate causes to check, in order:
1. An exception thrown during `setState(() => _index++)` → step content for index 1 failing to build (check `tutorialSteps()` in `tutorial_content.dart` for content that assumes a provider/scope not present in the dialog's context).
2. The gate firing during the router's setup→shell transition, with the dialog's navigator entry dropped when the shell rebuilds.
3. Theme/constraint problems at desktop window sizes (the "misshapen" report): the `Dialog` has `maxWidth: 420` but no height constraint or scrolling.

Record the actual cause in the commit body. The steps below are required regardless of what the diagnosis finds; fix the diagnosed cause in addition if it isn't covered by them.

- [ ] **Step 2: Write the failing prefs tests**

Create `app/test/features/tutorial_prefs_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lootlog/features/tutorial/tutorial_prefs.dart';

void main() {
  test('encodes and decodes completion', () {
    expect(TutorialProgress.decode('true'),
        const TutorialProgress(completed: true, stepIndex: 0));
    expect(const TutorialProgress(completed: true, stepIndex: 0).encode(),
        'true');
  });

  test('encodes and decodes a mid-tour step', () {
    expect(TutorialProgress.decode('step:3'),
        const TutorialProgress(completed: false, stepIndex: 3));
    expect(const TutorialProgress(completed: false, stepIndex: 3).encode(),
        'step:3');
  });

  test('legacy and garbage values decode sanely', () {
    // Legacy file contents: 'true' (seen) / 'false' (not seen).
    expect(TutorialProgress.decode('false'),
        const TutorialProgress(completed: false, stepIndex: 0));
    expect(TutorialProgress.decode('step:-2'),
        const TutorialProgress(completed: false, stepIndex: 0));
    expect(TutorialProgress.decode('garbage'),
        const TutorialProgress(completed: false, stepIndex: 0));
  });
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run (from `app/`): `flutter test test/features/tutorial_prefs_test.dart`
Expected: FAIL — `TutorialProgress` does not exist.

- [ ] **Step 4: Implement resumable progress in tutorial_prefs.dart**

Rewrite `app/lib/features/tutorial/tutorial_prefs.dart`:

```dart
/// Device-local persistence for first-use tour progress.
///
/// Like the presentation skin, this is a per-device preference (not household
/// data), so it lives in a tiny file in the app documents directory rather
/// than the event log. The file keeps its legacy name and 'true' payload so
/// devices upgrading from the boolean era read as completed.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<File> _tutorialFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File(p.join(dir.path, 'tutorial_seen.txt'));
}

/// How far this device has gotten through the tour.
@immutable
class TutorialProgress {
  const TutorialProgress({required this.completed, required this.stepIndex});

  /// Finished or explicitly skipped — the gate never auto-shows again.
  final bool completed;

  /// The step to resume at when not [completed].
  final int stepIndex;

  static const done = TutorialProgress(completed: true, stepIndex: 0);
  static const fresh = TutorialProgress(completed: false, stepIndex: 0);

  /// Decodes a stored value. 'true' (also the legacy boolean file) means
  /// completed; 'step:N' resumes at N; anything else reads as fresh.
  static TutorialProgress decode(String raw) {
    final v = raw.trim();
    if (v == 'true') return done;
    if (v.startsWith('step:')) {
      final n = int.tryParse(v.substring('step:'.length)) ?? 0;
      return TutorialProgress(completed: false, stepIndex: n < 0 ? 0 : n);
    }
    return fresh;
  }

  String encode() => completed ? 'true' : 'step:$stepIndex';

  @override
  bool operator ==(Object other) =>
      other is TutorialProgress &&
      other.completed == completed &&
      other.stepIndex == stepIndex;

  @override
  int get hashCode => Object.hash(completed, stepIndex);
}

/// Loads the stored progress. A missing file (fresh install) reads as fresh.
Future<TutorialProgress> loadTutorialProgress() async {
  final f = await _tutorialFile();
  if (!f.existsSync()) return TutorialProgress.fresh;
  return TutorialProgress.decode(f.readAsStringSync());
}

/// Persists [progress].
Future<void> saveTutorialProgress(TutorialProgress progress) async {
  final f = await _tutorialFile();
  f.writeAsStringSync(progress.encode(), flush: true);
}

/// Tracks tour progress. Starts as completed (assume seen) and flips once the
/// async restore confirms otherwise, so the gate only triggers on a genuine
/// first run — never a flash while loading.
class TutorialProgressNotifier extends Notifier<TutorialProgress> {
  @override
  TutorialProgress build() {
    unawaited(_restore());
    return TutorialProgress.done;
  }

  Future<void> _restore() async {
    final loaded = await loadTutorialProgress();
    if (loaded != state) state = loaded;
  }

  /// Records that the tour was finished or explicitly skipped.
  Future<void> markCompleted() async {
    state = TutorialProgress.done;
    await saveTutorialProgress(state);
  }

  /// Records the step to resume at after a mid-tour dismissal.
  Future<void> saveStep(int stepIndex) async {
    state = TutorialProgress(completed: false, stepIndex: stepIndex);
    await saveTutorialProgress(state);
  }

  /// Resets progress so the tour shows again (Settings replay / tests).
  Future<void> reset() async {
    state = TutorialProgress.fresh;
    await saveTutorialProgress(state);
  }
}

/// This device's first-use tour progress.
final tutorialProgressProvider =
    NotifierProvider<TutorialProgressNotifier, TutorialProgress>(
        TutorialProgressNotifier.new);
```

- [ ] **Step 5: Run the prefs tests to verify they pass**

Run (from `app/`): `flutter test test/features/tutorial_prefs_test.dart`
Expected: PASS

- [ ] **Step 6: Update the tour dialog: resume, complete-only-on-intent, desktop-safe layout**

In `app/lib/features/tutorial/tutorial.dart`:

1. `TutorialTour.show` resumes and only completes on intent — replace with:

```dart
abstract final class TutorialTour {
  /// Shows the tour, resuming at the saved step. Finishing or pressing Skip
  /// marks it completed; any other dismissal saves the current step so a
  /// fresh launch resumes there.
  static Future<void> show(BuildContext context, WidgetRef ref) async {
    final isAdventure = ref.read(appSkinProvider) == AppSkin.adventure;
    final progress = ref.read(tutorialProgressProvider);
    final steps = tutorialSteps(isAdventure: isAdventure);
    final startAt = progress.completed
        ? 0
        : progress.stepIndex.clamp(0, steps.length - 1);
    // `true` = completed (Done or Skip); null = dismissed some other way
    // (barrier tap, navigator swap) — resume at the last shown step.
    final completed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _TutorialDialog(steps: steps, startAt: startAt),
    );
    final notifier = ref.read(tutorialProgressProvider.notifier);
    if (completed == true) {
      await notifier.markCompleted();
    } else {
      await notifier.saveStep(_TutorialDialogState.lastShownStep);
    }
  }
}
```

Track the last-visible step with a static (`_TutorialDialogState.lastShownStep`, updated in `initState` and in `_next`/`_back`) so a null outcome still knows where to resume; a static is acceptable because at most one tour dialog exists at a time.

2. `_TutorialDialog` gains `startAt` and pops with the outcome:

```dart
class _TutorialDialog extends StatefulWidget {
  const _TutorialDialog({required this.steps, required this.startAt});

  final List<TutorialStep> steps;
  final int startAt;

  @override
  State<_TutorialDialog> createState() => _TutorialDialogState();
}
```

In `_TutorialDialogState`: add `static int lastShownStep = 0;`; `_index` initializes to `widget.startAt` in `initState` (also setting `lastShownStep = widget.startAt`); `_next()` pops with `Navigator.of(context).pop(true)` on the last step; the Skip button pops with `pop(true)` as well (skipping is an explicit choice to complete); `_next`/`_back` update `lastShownStep = _index` after each `setState`.

3. Desktop-safe layout — in `build`, constrain height and make the content scrollable:

```dart
    return Dialog(
      shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheet),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 560),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              // ... existing children unchanged ...
            ),
          ),
        ),
      ),
    );
```

4. `TutorialGate` reads the new provider:

```dart
class _TutorialGateState extends ConsumerState<TutorialGate> {
  bool _triggered = false;

  void _maybeTrigger(TutorialProgress progress) {
    if (progress.completed || _triggered) return;
    _triggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(TutorialTour.show(context, ref));
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<TutorialProgress>(
        tutorialProgressProvider, (_, next) => _maybeTrigger(next));
    _maybeTrigger(ref.watch(tutorialProgressProvider));
    return widget.child;
  }
}
```

Note `_triggered` stays true after a mid-tour dismissal within the same session (no nag loop); the resume happens on next launch, matching the spec.

5. Fix all other references to the old provider: search the repo for `tutorialSeenProvider`, `markSeen`, `loadTutorialSeen`, `saveTutorialSeen` (`app_shell.dart`, `settings_screen.dart`, any tests) and migrate them (`Settings → Tutorial` replay should call `reset()` then `TutorialTour.show`, or simply `show` — keep its current behavior, just compiling against the new API).

6. Apply the Step-1 diagnosis fix if it isn't already covered (e.g. if step content crashed on build, fix `tutorial_content.dart`; if the router transition dropped the dialog, show the tour via the shell's post-transition context).

- [ ] **Step 7: Verify the walkthrough on Windows**

Run (from `app/`): `flutter run -d windows` with cleared prefs. Confirm: dialog renders cleanly; Next advances through every step; Done completes; closing the app mid-tour and relaunching resumes at the same step; Settings replay works; a completed tour never auto-shows again.

- [ ] **Step 8: Run `./check.sh` and commit**

```bash
./check.sh
git add app/lib/features/tutorial/ app/test/features/tutorial_prefs_test.dart
# plus app_shell.dart / settings_screen.dart if they changed
git commit -m "fix(tutorial): resumable progress and desktop-safe layout

Any dismissal used to mark the tour seen forever, so one broken popup on
Windows killed onboarding permanently. Progress now persists per step
(legacy 'true' files still read as completed), only Done/Skip complete the
tour, mid-way dismissals resume on next launch, and the dialog is height-
constrained and scrollable so desktop windows can't misshape it.

Diagnosed cause of the Next-closes-dialog report: <fill in from Step 1>"
```

---

## Manual Android device checklist (after all tasks, on the Android 17 phone)

Run these with a release or debug APK built from the branch; they verify the acceptance criteria CI cannot:

1. **Fresh install → onboarding completes** (Tasks 1+2): full wizard, "Begin the adventure" navigates to the app. If it fails, an inline error must appear — not a dead button.
2. **Pair via QR** (Task 3): Windows hub open on Sync & hubs; phone → Join an existing party → Scan the hub's QR code → fields prefill → pair and pull succeed with no sqlite errors.
3. **Member edit narration** (Tasks 4+5): edit a member's name → Activity shows "updated"; save without changes → no new Activity line; upload a portrait → "updated …'s portrait".
4. **Sprite render** (Task 6): with pixel tier active, the uploaded PNG shows in the party frame.

## Out of scope

Everything listed under "Out of scope" in the spec: setup-wizard features, domain-model changes, month-close concurrency, UX overhaul, Adventure redesign, art prompts, migration safety.
