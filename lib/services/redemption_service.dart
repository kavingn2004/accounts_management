import '../data/finance_repository.dart';
import '../data/module_event.dart';
import 'quotes/investment_sync.dart';
import 'sip_service.dart';

/// Raised when a redemption doesn't make sense — more units than are held, or
/// nothing at all. Carries a message fit to show the user.
class RedemptionError implements Exception {
  const RedemptionError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Selling out of a holding, in whole or in part.
///
/// The counterpart to buying: an investment could only ever take money out of
/// an account, on the day it was created. This puts money back in.
///
/// **Net invested, not cost basis.** A redemption reduces `total_invested` by
/// the proceeds rather than by the original cost of those units, so the figure
/// means "cash still in this holding". Sell for more than you paid and it can
/// go negative — which is correct and readable: it says the holding has already
/// returned more than it cost. It also keeps XIRR honest, since a redemption is
/// simply a positive cash flow in the same series as the purchases.
class RedemptionService {
  RedemptionService({
    required FinanceRepository repo,
    DateTime Function()? clock,
  })  : _repo = repo,
        _now = clock ?? DateTime.now;

  final FinanceRepository _repo;
  final DateTime Function() _now;

  static double? _num(Json row, String key) =>
      (row[key] as num?)?.toDouble();

  /// What one unit of this holding is currently worth, or null when the
  /// holding isn't described in units at all.
  ///
  /// The last priced figure is preferred over value ÷ quantity because it is
  /// the price the row was actually valued at; the division is a fallback for
  /// rows that hold units but were never priced.
  static double? unitPrice(Json row) {
    final quantity = _num(row, InvestmentFields.quantity);
    if (quantity == null || quantity <= 0) return null;
    final last = _num(row, InvestmentFields.lastPrice);
    if (last != null && last > 0) return last;
    final value = _num(row, InvestmentFields.value);
    if (value == null || value <= 0) return null;
    return value / quantity;
  }

  /// Sell [units] of [row] for [proceeds], optionally crediting [account].
  ///
  /// Pass `units: 0` for a holding that has no unit count — the whole thing is
  /// then described by [proceeds] alone.
  Future<void> redeem(
    Json row, {
    required double units,
    required double proceeds,
    String? account,
  }) async {
    if (proceeds <= 0) {
      throw const RedemptionError('Enter an amount to redeem');
    }
    final held = _num(row, InvestmentFields.quantity) ?? 0;
    if (units < 0) {
      throw const RedemptionError('Units cannot be negative');
    }
    if (units > held + 1e-9) {
      throw const RedemptionError('You hold fewer units than that');
    }

    final id = row['id'].toString();
    final valueBefore = _num(row, InvestmentFields.value) ?? 0;
    final valueAfter = valueBefore - proceeds;

    if (SipService.isSip(row)) {
      // A SIP's units are derived from its ledger on every refresh, so writing
      // them onto the row would be overwritten within moments. The exit has to
      // live in the ledger, as a negative purchase.
      await _repo.insert(SipFields.table, {
        InstallmentFields.parentId: id,
        InstallmentFields.date: SipService.isoDay(_now()),
        InstallmentFields.amount: -proceeds,
        InstallmentFields.units: -units,
        'units_override': true,
        InstallmentFields.source: 'redemption',
        InstallmentFields.nav: units > 0 ? proceeds / units : null,
        InstallmentFields.navDate: SipService.isoDay(_now()),
        // The cash decision was made here and now; the due-installment banner
        // must never ask about it again.
        InstallmentFields.cashPosted: true,
        if (account != null) InstallmentFields.account: account,
      });
    } else {
      // Rows created before the running total existed carry the same figure
      // in `invested_amount` — the substitution FinanceMath makes too.
      final invested =
          _num(row, 'total_invested') ?? _num(row, 'invested_amount') ?? 0;
      final values = {
        if (held > 0) InvestmentFields.quantity: held - units,
        'total_invested': invested - proceeds,
        InvestmentFields.value: valueAfter,
      };
      await _repo.update(SipService.investmentsTable, id, values);
      row.addAll(values);
    }

    if (account != null) {
      await _repo.insert('cash_moves', {
        'account': account,
        'amount': proceeds, // money in
        'date': SipService.isoDay(_now()),
        'note': 'Redeemed ${row['name'] ?? 'investment'}',
      });
    }

    // Recorded as a decrement so the value curve steps down on the day of the
    // exit, rather than appearing to lose value for no reason.
    await logModuleEvent(
      _repo,
      ModuleEvent(
        parentId: id,
        parentType: SipService.investmentsTable,
        field: InvestmentFields.value,
        kind: EventKind.decrement,
        amount: proceeds,
        balanceAfter: valueAfter,
        date: _now(),
        account: account,
        note: 'Redemption',
      ),
    );
  }
}
