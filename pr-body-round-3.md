# Round 3: camp scene, text-adventure depth, homestead customization, update safety

Five tasks, one commit each, on top of `main` (round 2 was squash-merged as 1e5839f).

## 1. Adventure home is a camp outside the dungeon (ed9d1d0)

The Adventure dashboard now reads as a camp scene at both tiers, entirely art-free per the degradation ladder:

- **Text tier:** the camp header gathers the party roster around the campfire (styled text panels, member descriptions inline); the floor's monsters wait under **The Dungeon Entrance**.
- **Pixel tier:** the camp banner arranges roster sprite slots around a campfire slot — labelled placeholders that light up when art lands (new `campfire_idle_4f.png` documented in `docs/art-assets.md` + `docs/gemini-art-prompts.md`).
- Both tiers pin a **"Strike a monster — log a purchase"** bar outside the scroll view, so quick entry is always one tap from the scene and never scrolls away.
- Classic mode untouched; both skins render the same providers with identical numbers.

## 2. Text-adventure depth (3157776)

- The month-end encounter walkthrough names each monster's **champion** (owning member, or the linked pet for pet-owned categories) and echoes their user-written `descriptionText` onto the encounter page.
- New data-driven **camp ambience lines** (`assets/game/text/camp_ambience.json`, documented in `docs/voice-lines.md`); the pick is seeded by the date — a fresh line each day, no flicker per rebuild.
- The adventure log narrates divided spoils **per destination in game voice** (hurl at a quest boss / bank for the next floor / pocket / strike an OVERBUDGET) instead of one flat line.
- All cosmetic: strings decorate reducer events, never compute a cent.

## 3. Homestead customization (f3f8c8d)

- New stage-ladder editor: rename stages, edit thresholds (first stage locked at $0, strictly ascending, validated), add/remove stages, reset to defaults. Rename-the-flavour already existed; both persist as `CosmeticSet` events and sync like everything else.
- `stagesFromCosmetic`/`stagesToCosmetic` (pure, unit-tested) parse the ladder; any malformed value falls back to the default ladder.
- Each stage may carry **custom art from a user sprite blob** (same `pickAndIngestSprite` pipeline as member sprites), rendered pixelated, degrading to the labelled slot when the blob is missing.
- `BlobStore.referencedBlobs` now finds sprite shas nested inside structured cosmetic values, so stage art syncs to hubs and is never garbage-collected.
- Cosmetic only: display thresholds for the war-chest visualization; nothing financial is gated or changed.

## 4. Update safety — workstream G (61f2fe1)

Proves an app update preserves data and pairings:

- **Migration tests** (`test/data/migration_test.dart`): a real database file rewound to schema v1/v2 reopens under the current schema with the event log (integer cents exact), device setup, pull cursors, and hub pairings/tokens intact. Future schema bumps only need a new entry in `_tablesAddedAfter`.
- **Blob store:** a fresh store over the same root reads every blob; `blobs/<sha256>` layout asserted as a compatibility contract.
- **Secure storage (Sheets):** settings/credentials round-trip; corrupted or missing values decode to the off-by-default state — an update can never enable the only external service by itself.
- **Pref files:** the real loaders run against a faked documents dir — tutorial legacy boolean + `step:N`, skin, adventure tier, visibility, receipt-mode legacy `on`/`off`, offloaded-hash memory; unknown values always fall back to safe defaults.
- **`docs/update-safety.md`**: per-surface guarantees, additive-only migration rules, and a manual release-APK-over-APK upgrade checklist.
- New **test-only** dev dependency `path_provider_platform_interface` (already in the graph via `path_provider`) to substitute a temp documents dir.

## 5. Round-1 review cleanup batch (282a4e1)

- Bounded the while-Next wizard walk in `setup_finish_error_test.dart` (fails instead of hanging); fixed the first test's stale comment (throw site is `buildInput`, not the DB write).
- Join-party screen: the post-scan "Scanned!" message is now a friendly notice in primary styling, not error styling; error/notice clear each other.
- Extracted shared `classifyMemberSet` (features/shared) replacing duplicated logic in `activity_model.dart`/`change_log_model.dart`; added the missing retirement-case test to `change_log_model_test.dart`.
- `_SpritePreview` memoizes its blob-load future per sha — member-sheet rebuilds no longer refetch and flash.

## Testing

- `bash check.sh` (dart analyze + flutter test) before every commit. Every run ended with exactly the **13 pre-existing golden failures** this machine shows on clean checkouts (stale local golden baseline) — zero new failures all round.
- The known `actions_test detachReceipt` flake appeared once (Task 5 run) and passes in isolation — third sighting overall; worth a future look.
- **Note for the golden-authoring machine:** the camp-scene restructure changes the pixel/text adventure renders, so `test/game/pixel/pixel_adventure_golden_test.dart` (and the legacy `adventure_golden_test.dart` goldens if kept) need `--update-goldens` regeneration there.
- TDD used for all pure logic: encounters champion mapping, camp-ambience parsing, spoils log narration, homestead ladder parsing, blob referencing, migrations, pref loaders.

## Firewall

No reducer changes. All game/homestead features append only `CosmeticSet` events or read reducer output; the cosmetic-stripped-ledger firewall test still passes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
