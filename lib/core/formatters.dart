import 'package:intl/intl.dart';
import 'config.dart';

/// Format a number as currency using Indian digit grouping, e.g. ₹8,42,600.
///
/// Paise are shown only when the amount actually has them — the redesign's
/// figures are whole rupees, but a ledger must never silently round money away.
String money(num? value) {
  final v = value ?? 0;
  final whole = v == v.roundToDouble();
  final f = NumberFormat.currency(
    locale: 'en_IN',
    symbol: AppConfig.currencySymbol,
    decimalDigits: whole ? 0 : 2,
  );
  return f.format(v);
}

/// Parse a yyyy-MM-dd (or ISO) string into a friendly date, e.g. 22 May 2026.
String prettyDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return DateFormat('d MMM yyyy').format(d);
}

/// yyyy-MM-dd for sending dates to Postgres `date` columns.
String isoDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
