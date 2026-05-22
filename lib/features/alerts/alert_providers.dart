import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/providers.dart';
import 'alert_engine.dart';
import 'alert_model.dart';

/// Overall monthly expense limit (Phase 2 will make this user-editable + per
/// category). Demo default is intentionally low so the budget alert shows.
final monthlyBudgetProvider = StateProvider<double>((_) => 10000);

/// Computed alerts derived from the user's current data.
final alertsProvider = FutureProvider<List<AppAlert>>((ref) async {
  final repo = ref.read(repoProvider);
  final bills = await repo.list('bills');
  final loans = await repo.list('loans');
  final goals = await repo.list('savings_goals');
  final debtors = await repo.list('debtors');
  final creditors = await repo.list('creditors');
  final expenses = await repo.list('expenses');
  final income = await repo.list('income');

  final computed = AlertEngine.generate(
    bills: bills,
    loans: loans,
    goals: goals,
    debtors: debtors,
    creditors: creditors,
    expenses: expenses,
    income: income,
    monthlyBudget: ref.watch(monthlyBudgetProvider),
  );

  // User-created alerts stored in the alerts table.
  final stored = await repo.list('alerts');
  final custom = stored.map((r) => AppAlert(
        id: r['id']?.toString(),
        key: 'custom:${r['id']}',
        severity: alertSeverityFrom(r['severity']),
        title: (r['title'] ?? '').toString(),
        message: (r['message'] ?? '').toString(),
      ));

  final all = [...computed, ...custom]
    ..sort((a, b) => a.severity.rank.compareTo(b.severity.rank));
  return all;
});

/// Keys of alerts the user has already seen (cleared the badge for).
final seenAlertsProvider = StateProvider<Set<String>>((_) => {});

/// Keys of computed alerts the user dismissed this session (hidden from view).
final dismissedAlertsProvider = StateProvider<Set<String>>((_) => {});

/// Alerts actually shown: computed + custom, minus dismissed ones.
final visibleAlertsProvider = Provider<AsyncValue<List<AppAlert>>>((ref) {
  final async = ref.watch(alertsProvider);
  final dismissed = ref.watch(dismissedAlertsProvider);
  return async
      .whenData((list) => list.where((a) => !dismissed.contains(a.key)).toList());
});

/// Unread alert count for the badge.
final unreadAlertCountProvider = Provider<int>((ref) {
  final alerts = ref.watch(visibleAlertsProvider).valueOrNull ?? const [];
  final seen = ref.watch(seenAlertsProvider);
  return alerts.where((a) => !seen.contains(a.key)).length;
});
