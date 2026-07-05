/// Tax package export: a zip containing `summary.csv` (every deductible purchase
/// in a chosen calendar year) plus every referenced receipt file, named
/// `<date>_<user>_<slice>_<amount>_<n>.<ext>`.
///
/// The package *contents* — the CSV text and the receipt file list — are built
/// by the pure, unit-tested [buildTaxPackage]. Only [writeTaxPackageZip] touches
/// blobs and produces the archive bytes.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../domain/money.dart';
import '../../domain/state.dart';
import '../../domain/time.dart';
import '../blobs/blob_store.dart';
import '../library/receipt_library.dart' show extensionForMime, sanitizeSegment;

/// One receipt file to include in the package: its in-zip [filename] and the
/// content-addressed [sha256] blob whose bytes fill it.
class TaxReceiptFile {
  const TaxReceiptFile({required this.filename, required this.sha256});

  final String filename;
  final String sha256;

  @override
  bool operator ==(Object other) =>
      other is TaxReceiptFile &&
      other.filename == filename &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(filename, sha256);

  @override
  String toString() => 'TaxReceiptFile($filename <- $sha256)';
}

/// The pure contents of a tax package: the `summary.csv` text and the receipt
/// files it references.
class TaxPackage {
  const TaxPackage({required this.csv, required this.receipts});

  final String csv;
  final List<TaxReceiptFile> receipts;
}

/// CSV column header for the deductible summary.
const List<String> kTaxSummaryColumns = [
  'date',
  'user',
  'slice',
  'merchant',
  'amount',
  'shared',
  'note',
  'receipt filename',
];

/// Builds the tax package contents for [year] from the derived [state]. Pure:
/// no IO. [userNames] maps user ids to display names for the CSV and filenames.
TaxPackage buildTaxPackage(
  HouseholdState state, {
  required int year,
  required Map<String, String> userNames,
}) {
  final deductibles = [...(state.deductibleByYear[year] ?? const [])];
  // Deterministic order: date, user, slice, amount, then purchaseId tie-break.
  deductibles.sort((a, b) {
    final da = _householdDay(a.occurredAt);
    final db = _householdDay(b.occurredAt);
    var c = da.compareTo(db);
    if (c != 0) return c;
    c = (userNames[a.userId] ?? a.userId)
        .compareTo(userNames[b.userId] ?? b.userId);
    if (c != 0) return c;
    c = a.sliceName.compareTo(b.sliceName);
    if (c != 0) return c;
    c = a.amountCents.compareTo(b.amountCents);
    if (c != 0) return c;
    return a.purchaseId.compareTo(b.purchaseId);
  });

  final receipts = <TaxReceiptFile>[];
  final baseCounts = <String, int>{}; // base name -> assigned count so far
  final rows = <List<String>>[];

  for (final d in deductibles) {
    final date = _householdDay(d.occurredAt);
    final user = userNames[d.userId] ?? d.userId;
    final base = '${date}_'
        '${sanitizeSegment(user, fallback: 'user')}_'
        '${sanitizeSegment(d.sliceName, fallback: 'slice')}_'
        '${Money(d.amountCents).format()}';

    final filenames = <String>[];
    final shas = [...d.receiptShas]..sort();
    for (final sha in shas) {
      final n = (baseCounts[base] ?? 0) + 1;
      baseCounts[base] = n;
      final mime =
          state.purchases[d.purchaseId]?.receipts
                  .firstWhere(
                    (r) => r.sha256 == sha,
                    orElse: () => const ReceiptRef(
                      sha256: '',
                      mimeType: 'application/octet-stream',
                      sizeBytes: 0,
                    ),
                  )
                  .mimeType ??
              'application/octet-stream';
      final filename = '${base}_$n.${extensionForMime(mime)}';
      filenames.add(filename);
      receipts.add(TaxReceiptFile(filename: filename, sha256: sha));
    }

    rows.add([
      date,
      user,
      d.sliceName,
      d.merchant ?? '',
      Money(d.amountCents).format(),
      d.shared ? 'yes' : 'no',
      d.note ?? '',
      filenames.join('; '),
    ]);
  }

  final csv = StringBuffer()..writeln(_csvRow(kTaxSummaryColumns));
  for (final r in rows) {
    csv.writeln(_csvRow(r));
  }
  return TaxPackage(csv: csv.toString(), receipts: receipts);
}

/// Assembles the package zip bytes: `summary.csv` plus each referenced receipt
/// read from [blobs]. The only impure step.
Future<Uint8List> writeTaxPackageZip(
  HouseholdState state, {
  required int year,
  required Map<String, String> userNames,
  required BlobStore blobs,
}) async {
  final pkg = buildTaxPackage(state, year: year, userNames: userNames);
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes('summary.csv', utf8.encode(pkg.csv)),
    );
  for (final r in pkg.receipts) {
    if (!await blobs.exists(r.sha256)) continue;
    final bytes = await blobs.read(r.sha256);
    archive.addFile(ArchiveFile.bytes('receipts/${r.filename}', bytes));
  }
  return ZipEncoder().encodeBytes(archive);
}

String _householdDay(DateTime instant) {
  final u = instant.toUtc();
  final local = u.add(vancouverUtcOffset(u));
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// Serializes one CSV record, quoting fields that need it (comma, quote, CR/LF)
/// per RFC 4180 and doubling embedded quotes.
String _csvRow(List<String> fields) => fields.map(_csvField).join(',');

String _csvField(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}
