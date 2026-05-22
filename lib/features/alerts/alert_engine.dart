import '../../core/formatters.dart';
import '../../data/finance_repository.dart';
import 'alert_model.dart';

/// Derives alerts from the user's data. Pure functions — no I/O — so it works
/// identically in demo and real mode, and is easy to unit-test.
class AlertEngine {
  static const int billLeadDays = 3;
  static const int debtLeadDays = 5;

  static List<AppAlert> generate({
    required List<Json> bills,
    required List<Json> loans,
    required List<Json> goals,
    required List<Json> debtors,
    required List<Json> creditors,
    required List<Json> expenses,
    required List<Json> income,
    required double monthlyBudget,
    DateTime? now,
  }) {
    final today = now ?? DateTime.now();
    final out = <AppAlert>[];
    double num$(Json r, String k) => (r[k] as num?)?.toDouble() ?? 0;

    // ---- Bills ----
    for (final b in bills) {
      if ((b['status'] ?? '') == 'paid') continue;
      final dueDay = (b['due_day'] as num?)?.toInt();
      if (dueDay == null) continue;
      final name = (b['name'] ?? 'Bill').toString();
      final amt = money(num$(b, 'amount'));
      if (today.day <= dueDay) {
        final days = dueDay - today.day;
        if (days <= billLeadDays) {
          out.add(AppAlert(
            key: 'bill:${b['id']}',
            severity: AlertSeverity.warning,
            title: '$name due ${days == 0 ? 'today' : 'in $days day(s)'}',
            message: '$amt due on day $dueDay of the month.',
          ));
        }
      } else {
        out.add(AppAlert(
          key: 'bill:${b['id']}',
          severity: AlertSeverity.critical,
          title: '$name overdue',
          message: '$amt was due on day $dueDay (${today.day - dueDay} day(s) ago).',
        ));
      }
    }

    // ---- Loans (active) ----
    for (final l in loans) {
      if ((l['status'] ?? 'active') != 'active') continue;
      final lender = (l['lender'] ?? 'Loan').toString();
      final emi = num$(l, 'emi');
      final outstanding = num$(l, 'outstanding');
      final rate = num$(l, 'interest_rate');
      final interest = outstanding * (rate / 100 / 12);
      if (outstanding > 0 && outstanding < emi) {
        out.add(AppAlert(
          key: 'loan-end:${l['id']}',
          severity: AlertSeverity.info,
          title: '$lender almost cleared 🎉',
          message: 'Only ${money(outstanding)} left to pay off.',
        ));
      } else {
        out.add(AppAlert(
          key: 'loan:${l['id']}',
          severity: AlertSeverity.info,
          title: '$lender EMI ${money(emi)}',
          message: 'About ${money(interest)} interest accrues this month.',
        ));
      }
    }

    // ---- Expense limit (overall monthly budget) ----
    final monthExpense = expenses
        .where((e) => _thisMonth(e['date'], today))
        .fold(0.0, (a, e) => a + num$(e, 'amount'));
    if (monthlyBudget > 0) {
      final pct = monthExpense / monthlyBudget * 100;
      if (pct >= 100) {
        out.add(AppAlert(
          key: 'budget',
          severity: AlertSeverity.critical,
          title: 'Over budget',
          message:
              'Spent ${money(monthExpense)} of ${money(monthlyBudget)} (${pct.round()}%).',
        ));
      } else if (pct >= 80) {
        out.add(AppAlert(
          key: 'budget',
          severity: AlertSeverity.warning,
          title: 'Approaching budget',
          message:
              'Spent ${money(monthExpense)} of ${money(monthlyBudget)} (${pct.round()}%).',
        ));
      }
    }

    // ---- Savings milestones ----
    for (final g in goals) {
      final target = num$(g, 'target_amount');
      final saved = num$(g, 'saved_amount');
      if (target <= 0) continue;
      final pct = saved / target * 100;
      final name = (g['name'] ?? 'Goal').toString();
      if (pct >= 100) {
        out.add(AppAlert(
          key: 'goal:${g['id']}',
          severity: AlertSeverity.info,
          title: '$name reached 🎉',
          message: 'You hit your ${money(target)} goal.',
        ));
      } else if (pct >= 50) {
        out.add(AppAlert(
          key: 'goal:${g['id']}',
          severity: AlertSeverity.info,
          title: '$name ${pct.round()}% funded',
          message: '${money(saved)} of ${money(target)} saved.',
        ));
      }
    }

    // ---- Debtors / creditors due ----
    void debtAlerts(List<Json> rows, bool owedToYou) {
      for (final r in rows) {
        if ((r['status'] ?? '') == 'settled') continue;
        final due = DateTime.tryParse((r['due_date'] ?? '').toString());
        if (due == null) continue;
        final days = DateTime(due.year, due.month, due.day)
            .difference(DateTime(today.year, today.month, today.day))
            .inDays;
        final who = (r['person_name'] ?? 'Someone').toString();
        final amt = money(num$(r, 'amount'));
        final verb = owedToYou ? 'owed to you' : 'you owe';
        if (days < 0) {
          out.add(AppAlert(
            key: 'debt:${r['id']}',
            severity: AlertSeverity.critical,
            title: '$who overdue',
            message: '$amt ($verb) was due ${-days} day(s) ago.',
          ));
        } else if (days <= debtLeadDays) {
          out.add(AppAlert(
            key: 'debt:${r['id']}',
            severity: AlertSeverity.warning,
            title: '$who due ${days == 0 ? 'today' : 'in $days day(s)'}',
            message: '$amt $verb.',
          ));
        }
      }
    }

    debtAlerts(debtors, true);
    debtAlerts(creditors, false);

    // ---- Cashflow ----
    final monthIncome = income
        .where((e) => _thisMonth(e['date'], today))
        .fold(0.0, (a, e) => a + num$(e, 'amount'));
    if (monthExpense > monthIncome && (monthExpense + monthIncome) > 0) {
      out.add(AppAlert(
        key: 'cashflow',
        severity: AlertSeverity.warning,
        title: 'Spending exceeds income',
        message:
            'This month: spent ${money(monthExpense)} vs earned ${money(monthIncome)}.',
      ));
    }

    out.sort((a, b) => a.severity.rank.compareTo(b.severity.rank));
    return out;
  }

  static bool _thisMonth(dynamic dateStr, DateTime today) {
    final d = DateTime.tryParse((dateStr ?? '').toString());
    return d != null && d.year == today.year && d.month == today.month;
  }
}
