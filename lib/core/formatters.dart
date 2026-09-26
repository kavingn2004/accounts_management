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

/// Compact age of a figure: "just now", "5m ago", "2h ago", "3d ago".
///
/// For live prices, where how old a number is matters more than the clock time
/// it was taken at. Beyond a week it falls back to a plain date, because "9d
/// ago" is harder to place than "24 Jul".
String ago(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 90) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays <= 7) return '${d.inDays}d ago';
  return DateFormat('d MMM').format(t);
}

/// A holding at a readable precision: 12, 0.35, 2.619.
///
/// Units divide out of money and NAV, so they arrive with the full baggage of
/// binary floating point — 2.61858342317984 is not a figure anyone holds. Three
/// decimals is what fund houses themselves publish.
String quantityText(num q) {
  if (q == q.roundToDouble()) return q.toInt().toString();
  final fixed = q.toStringAsFixed(3);
  // Trim trailing zeros so 2.500 reads as 2.5, but never leave a bare dot.
  return fixed.contains('.')
      ? fixed.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')
      : fixed;
}
