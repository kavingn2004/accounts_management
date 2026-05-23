import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../core/formatters.dart';
import '../../data/finance_repository.dart';
import '../../models/field_spec.dart';

/// Generates CSV / PDF dumps of a module's rows and hands them to the
/// platform share sheet (UIActivityViewController on iOS, chooser on Android,
/// Web Share API / download on web).
class ExportService {
  static Future<void> exportCsv(EntityConfig cfg, List<Json> rows) async {
    final csv = _toCsv(cfg, rows);
    final bytes = Uint8List.fromList(utf8.encode(csv));
    await _shareBytes(bytes, '${cfg.table}_${_stamp()}.csv', 'text/csv');
  }

  static Future<void> exportPdf(EntityConfig cfg, List<Json> rows) async {
    final doc = pw.Document();
    final totals = _totals(cfg, rows);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        header: (ctx) => pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 12),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(color: PdfColors.blue900, width: 1.5),
            ),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                cfg.title,
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.blue900,
                ),
              ),
              pw.Text(
                'Exported ${DateFormat('d MMM yyyy, HH:mm').format(DateTime.now())}',
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
              ),
            ],
          ),
        ),
        footer: (ctx) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (ctx) => [
          pw.SizedBox(height: 10),
          _pdfTable(cfg, rows),
          pw.SizedBox(height: 12),
          if (totals != null)
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Text(
                'Total: ${totals.formatted}   ·   ${rows.length} entries',
                style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );

    final bytes = await doc.save();
    await _shareBytes(
      bytes,
      '${cfg.table}_${_stamp()}.pdf',
      'application/pdf',
    );
  }

  // ---- CSV ----
  static String _toCsv(EntityConfig cfg, List<Json> rows) {
    final headers = cfg.fields.map((f) => f.label).toList();
    final lines = <String>[headers.map(_csvEscape).join(',')];
    for (final r in rows) {
      lines.add(
        cfg.fields.map((f) => _csvEscape(_cellText(r, f))).join(','),
      );
    }
    return lines.join('\n');
  }

  static String _csvEscape(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  // ---- PDF table ----
  static pw.Widget _pdfTable(EntityConfig cfg, List<Json> rows) {
    final headers = cfg.fields.map((f) => f.label).toList();
    final data = rows
        .map((r) => cfg.fields.map((f) => _cellText(r, f)).toList())
        .toList();
    return pw.TableHelper.fromTextArray(
      headers: headers,
      data: data,
      cellAlignment: pw.Alignment.centerLeft,
      headerAlignment: pw.Alignment.centerLeft,
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
      headerStyle: pw.TextStyle(
        fontWeight: pw.FontWeight.bold,
        color: PdfColors.white,
      ),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.blue900),
      cellStyle: const pw.TextStyle(fontSize: 10),
      cellPadding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 6),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
    );
  }

  // ---- shared helpers ----
  static String _cellText(Json row, FieldSpec f) {
    final v = row[f.key];
    if (v == null) return '';
    switch (f.type) {
      case FieldType.date:
        return prettyDate(v.toString());
      case FieldType.number:
        // Amount-like fields render with currency for readability.
        if (f.key == 'amount' ||
            f.key.endsWith('_amount') ||
            f.key == 'current_value' ||
            f.key == 'invested_amount' ||
            f.key == 'outstanding' ||
            f.key == 'emi') {
          return money(v as num);
        }
        return v.toString();
      default:
        return v.toString();
    }
  }

  /// If the config has an "amount"-like field, returns the sum across [rows].
  static _Totals? _totals(EntityConfig cfg, List<Json> rows) {
    final hasAmount = cfg.fields.any((f) => f.key == 'amount');
    if (!hasAmount) return null;
    final sum = rows.fold<double>(
      0,
      (a, r) => a + ((r['amount'] as num?)?.toDouble() ?? 0),
    );
    return _Totals(sum);
  }

  static String _stamp() =>
      DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());

  static Future<void> _shareBytes(
    Uint8List bytes,
    String filename,
    String mime,
  ) async {
    if (kIsWeb) {
      await Share.shareXFiles(
        [XFile.fromData(bytes, name: filename, mimeType: mime)],
        fileNameOverrides: [filename],
      );
      return;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: mime, name: filename)],
    );
  }
}

class _Totals {
  _Totals(this.amount);
  final double amount;
  String get formatted => money(amount);
}
