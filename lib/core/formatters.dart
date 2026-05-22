import 'package:intl/intl.dart';
import 'config.dart';

/// Format a number as currency, e.g. ₹1,250.00
String money(num? value) {
  final f = NumberFormat.currency(
    symbol: AppConfig.currencySymbol,
    decimalDigits: 2,
  );
  return f.format(value ?? 0);
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
