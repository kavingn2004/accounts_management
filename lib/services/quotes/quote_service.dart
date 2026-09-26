import 'package:http/http.dart' as http;

import 'coingecko_source.dart';
import 'mf_source.dart';
import 'quote.dart';
import 'quote_source.dart';
import 'yahoo_source.dart';

/// One symbol to price, together with the investment type that decides where
/// the price comes from.
class QuoteRequest {
  const QuoteRequest(this.symbol, this.type);
  final String symbol;

  /// The row's `type` value: stock / fund / mf / sip / crypto / gold / ...
  final String type;

  /// Cache identity. Two rows holding the same symbol under the same type ask
  /// one question between them.
  String get key => '${type.toLowerCase()}|${symbol.trim().toLowerCase()}';
}

/// The outcome of one round of fetching: what was priced, and why the rest
/// were not. Both halves matter — a caller that only reads [quotes] would show
/// a stale figure with no explanation.
class QuoteBatch {
  const QuoteBatch(this.quotes, this.failures);
  final Map<String, Quote> quotes;
  final Map<String, QuoteFailure> failures;

  bool get isEmpty => quotes.isEmpty && failures.isEmpty;
}

/// Routes symbols to the right source, batches what can be batched, and
/// remembers what it just fetched.
///
/// The throttle is the reason this class exists at all: opening the Investment
/// screen must not fire a request per row per visit. Mutual fund NAV moves once
/// a day and the free crypto tier is rate-limited, so a cached price inside the
/// window is served without touching the network. Pull-to-refresh passes
/// `force: true`, because a user who explicitly asked for fresh prices should
/// get them.
class QuoteService {
  QuoteService({
    http.Client? client,
    Map<String, QuoteSource>? sources,
    this.throttle = const Duration(minutes: 15),
    DateTime Function()? clock,
  })  : _client = client ?? http.Client(),
        _sources = sources ?? defaultSources,
        _now = clock ?? DateTime.now;

  final http.Client _client;
  final Map<String, QuoteSource> _sources;
  final Duration throttle;
  final DateTime Function() _now;

  final Map<String, Quote> _cache = {};
  final Map<String, DateTime> _fetchedAt = {};

  /// Investment type → where its prices come from. Types absent here (`fd`,
  /// `other`) have no market price and stay manual, which is the honest
  /// answer for a fixed deposit.
  static const Map<String, QuoteSource> defaultSources = {
    'stock': YahooSource(),
    'mf': MutualFundSource(),
    'sip': MutualFundSource(),
    'fund': MutualFundSource(),
    'crypto': CoinGeckoSource(),
    'gold': GoldSource(),
  };

  /// The source for an investment type, or null when the type has no live
  /// price. Callers use this to decide whether to offer a symbol field at all.
  QuoteSource? sourceFor(String type) => _sources[type.trim().toLowerCase()];

  /// Whether this type can be priced from the platform the app is running on.
  bool isLiveHere(String type) => sourceFor(type)?.availableHere ?? false;

  /// Price every request, grouped so each source is called once.
  ///
  /// Never throws: a source that fails takes only its own symbols down with it,
  /// reported in [QuoteBatch.failures].
  Future<QuoteBatch> fetch(
    List<QuoteRequest> requests, {
    bool force = false,
  }) async {
    final quotes = <String, Quote>{};
    final failures = <String, QuoteFailure>{};
    final pending = <QuoteSource, List<QuoteRequest>>{};

    for (final r in requests) {
      if (r.symbol.trim().isEmpty) continue;
      final source = sourceFor(r.type);
      if (source == null) {
        failures[r.key] = QuoteFailure(
            r.symbol, '${r.type} holdings have no live price source');
        continue;
      }
      if (!force && _isFresh(r.key)) {
        quotes[r.key] = _cache[r.key]!;
        continue;
      }
      if (!source.availableHere) {
        failures[r.key] = QuoteFailure(
          r.symbol,
          '${source.name} cannot be reached from a browser — '
              'use the mobile app for ${r.type} prices',
          unsupportedOnPlatform: true,
        );
        continue;
      }
      pending.putIfAbsent(source, () => []).add(r);
    }

    for (final entry in pending.entries) {
      final source = entry.key;
      // Deduplicated: ten rows of the same fund cost one lookup.
      final bySymbol = <String, List<QuoteRequest>>{};
      for (final r in entry.value) {
        bySymbol.putIfAbsent(r.symbol.trim(), () => []).add(r);
      }

      Map<String, Quote> fetched;
      try {
        fetched = await source.fetchAll(bySymbol.keys.toList(), _client);
      } on QuoteFailure catch (e) {
        // A batch-level failure (transport, rate limit) belongs to every
        // symbol in it, not just the one named in the exception.
        for (final r in entry.value) {
          failures[r.key] = QuoteFailure(r.symbol, e.message,
              unsupportedOnPlatform: e.unsupportedOnPlatform);
        }
        continue;
      } catch (e) {
        for (final r in entry.value) {
          failures[r.key] = QuoteFailure(r.symbol, 'price lookup failed');
        }
        continue;
      }

      final at = _now();
      for (final symbolEntry in bySymbol.entries) {
        final quote = fetched[symbolEntry.key];
        for (final r in symbolEntry.value) {
          if (quote == null) {
            failures[r.key] =
                QuoteFailure(r.symbol, 'no price returned by ${source.name}');
          } else {
            quotes[r.key] = quote;
            _cache[r.key] = quote;
            _fetchedAt[r.key] = at;
          }
        }
      }
    }

    return QuoteBatch(quotes, failures);
  }

  bool _isFresh(String key) {
    final at = _fetchedAt[key];
    if (at == null || !_cache.containsKey(key)) return false;
    return _now().difference(at) < throttle;
  }

  /// Drop everything cached. Used when the user edits a symbol, so the old
  /// instrument's price can't linger against the new one.
  void clearCache() {
    _cache.clear();
    _fetchedAt.clear();
  }
}
