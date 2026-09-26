import '../../data/finance_repository.dart';
import '../../models/field_spec.dart';

/// How a user action on a row reads on the History screen, e.g.
/// "Added Expenses · Groceries · ₹500".
String historyLabel(EntityConfig cfg, String verb, Json row) {
  String part(String Function(Json)? f) {
    if (f == null) return '';
    try {
      return f(row);
    } catch (_) {
      return '';
    }
  }

  return [
    '$verb ${cfg.title}',
    part(cfg.titleOf),
    part(cfg.trailingOf),
  ].where((p) => p.trim().isNotEmpty).join(' · ');
}
