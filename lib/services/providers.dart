import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config.dart';
import '../core/supabase_config.dart';
import '../data/finance_repository.dart';
import '../data/history.dart';
import '../data/local_repository.dart';
import '../data/local_store.dart';
import '../data/module_event.dart';
import '../data/nav_api.dart';
import '../data/nav_cache.dart';
import '../data/supabase_repository.dart';
import 'pin_service.dart';
import 'sip_service.dart';
import 'quotes/investment_sync.dart';
import 'quotes/quote_service.dart';
import 'ask/ask_service.dart';
import 'ask/llm_client.dart';
import 'redemption_service.dart';

/// Selected app theme (light / dark / follow system). Session-scoped.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

final pinServiceProvider = Provider<PinService>((ref) => PinService());

/// The on-device store. Overridden in main() with the initialized instance.
final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError('localStoreProvider must be overridden'),
);

/// The user's actions from the last [HistoryLog.keepFor], kept on this device.
final historyLogProvider = Provider<HistoryLog>(
  (ref) => HistoryLog(ref.watch(localStoreProvider)),
);

/// The app's repository. Wrapped in [HistoryRepository] so user actions can be
/// listed on the History screen and undone.
final repoProvider = Provider<FinanceRepository>((ref) {
  final FinanceRepository inner;
  if (SupabaseConfig.enabled) {
    inner = SupabaseRepository(Supabase.instance.client);
  } else {
    inner = LocalRepository(ref.watch(localStoreProvider));
  }
  return HistoryRepository(
    inner,
    ref.watch(historyLogProvider),
    // Rows that hang off a parent by `parent_id` (see EntityConfig.cascadeTables).
    childTables: const [moduleEventsTable, 'sip_installments', 'debt_payments'],
  );
});

/// Market prices for live-tracked investments. Kept app-wide so its throttle
/// and cache survive navigating away from the Investment screen and back —
/// a per-screen instance would re-fetch on every visit, which is exactly what
/// the throttle exists to prevent. Tests override it with a fake HTTP client.
final quoteServiceProvider = Provider<QuoteService>((ref) => QuoteService());

final investmentSyncProvider = Provider<InvestmentSync>(
  (ref) => InvestmentSync(
    repo: ref.watch(repoProvider),
    quotes: ref.watch(quoteServiceProvider),
  ),
);

/// Mutual-fund NAV history. The cache is app-wide so its once-a-day rule
/// applies across screens: the fund picker, the SIP engine and the detail
/// screen all read the same downloaded series.
final navApiProvider = Provider<NavApi>((ref) => NavApi());

final navCacheProvider = Provider<NavCache>(
  (ref) => NavCache(
    store: ref.watch(localStoreProvider),
    api: ref.watch(navApiProvider),
  ),
);

/// Maintains SIP installment ledgers and writes units to `quantity`.
/// Valuation stays with [investmentSyncProvider] — see [SipService].
final sipServiceProvider = Provider<SipService>(
  (ref) => SipService(
    repo: ref.watch(repoProvider),
    navs: ref.watch(navCacheProvider),
  ),
);

/// Selling out of a holding, back into an account.
final redemptionServiceProvider = Provider<RedemptionService>(
  (ref) => RedemptionService(repo: ref.watch(repoProvider)),
);

/// Answers questions about the user's own finances.
///
/// The model only ever chooses a tool; every figure is computed locally from
/// rows the repository returns. With no model reachable the service falls back
/// to keyword routing, so the feature still answers.
final askServiceProvider = Provider<AskService>(
  (ref) => AskService(
    repo: ref.watch(repoProvider),
    llm: AskConfig.enabled
        ? OpenAiCompatibleClient(
            baseUrl: AskConfig.baseUrl,
            model: AskConfig.model,
            apiKey: AskConfig.apiKey,
          )
        : null,
  ),
);

/// Supabase auth session stream (null when signed out). Only meaningful when
/// [SupabaseConfig.enabled]; emits null immediately otherwise.
final sessionProvider = StreamProvider<Session?>((ref) {
  if (!SupabaseConfig.enabled) return Stream.value(null);
  final auth = Supabase.instance.client.auth;
  return auth.onAuthStateChange.map((e) => e.session);
});

/// Whether a PIN has been set on this device.
final hasPinProvider = FutureProvider<bool>(
  (ref) => ref.read(pinServiceProvider).hasPin(),
);

/// Whether the user has entered their PIN this session (the in-app lock).
final unlockedProvider = StateProvider<bool>((ref) => false);

/// Bumped after any data mutation so dependent screens (e.g. the dashboard)
/// reload automatically instead of showing stale data.
final dataRevisionProvider = StateProvider<int>((ref) => 0);

