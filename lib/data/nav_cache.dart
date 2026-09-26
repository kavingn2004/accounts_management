import 'dart:convert';

import 'local_store.dart';
import 'nav_api.dart';

/// A NAV series together with how trustworthy its age makes it.
class CachedNav {
  const CachedNav(this.series, {required this.isStale, this.error});

  final NavSeries series;

  /// True when the series could not be refreshed and is being served from an
  /// earlier day's download. The UI says so rather than passing an old figure
  /// off as today's.
  final bool isStale;

  /// Why the refresh failed, when it did.
  final String? error;
}

/// Serves NAV history, downloading at most once per calendar day per scheme.
///
/// NAV is published once a day, so a second download the same day can only
/// return what is already held. That single rule is what keeps a normal
/// session at zero network calls, and it is also the offline story: yesterday's
/// history is a complete answer for everything except today's valuation.
class NavCache {
  NavCache({
    required LocalStore store,
    required NavApi api,
    DateTime Function()? clock,
  })  : _store = store,
        _api = api,
        _now = clock ?? DateTime.now;

  final LocalStore _store;
  final NavApi _api;
  final DateTime Function() _now;

  /// Kept in memory as well as on disk so several SIPs in one refresh sharing a
  /// scheme don't each pay to decode the stored blob.
  final Map<int, NavSeries> _memory = {};

  /// The series for [code], refreshing it if today's download hasn't happened.
  ///
  /// Throws [NavException] only when there is nothing to serve at all — no
  /// cache and no network. With a cache present, a failed refresh is reported
  /// through [CachedNav.isStale] instead, because a stale valuation is far
  /// better than none.
  Future<CachedNav> series(int code, {bool force = false}) async {
    final cached = _read(code);
    if (!force && cached != null && _isFromToday(cached)) {
      return CachedNav(cached, isStale: false);
    }

    try {
      final fresh = await _api.history(code);
      final stamped = NavSeries(
        code: fresh.code,
        schemeName: fresh.schemeName,
        fundHouse: fresh.fundHouse,
        navs: fresh.all,
        fetchedOn: _now(),
      );
      _memory[code] = stamped;
      try {
        await _store.writeNav('$code', jsonEncode(stamped.toJson()));
      } catch (_) {
        // Persisting is an optimisation, not the point. A full disk or a
        // browser's localStorage quota must not discard NAV we already hold —
        // it only means tomorrow pays for the download again.
      }
      return CachedNav(stamped, isStale: false);
    } on NavException catch (e) {
      if (cached != null) {
        return CachedNav(cached, isStale: true, error: e.message);
      }
      rethrow;
    }
  }

  /// What is on disk right now, without any network access. Used by screens
  /// that want to draw immediately and refresh behind the paint.
  NavSeries? peek(int code) => _read(code);

  NavSeries? _read(int code) {
    final inMemory = _memory[code];
    if (inMemory != null) return inMemory;

    final raw = _store.readNav('$code');
    if (raw == null || raw.isEmpty) return null;
    try {
      final series = NavSeries.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
      _memory[code] = series;
      return series;
    } catch (_) {
      // A blob written by an older format, or truncated. Drop it and let the
      // caller refetch rather than failing every valuation from now on.
      _store.removeNav('$code');
      return null;
    }
  }

  bool _isFromToday(NavSeries series) {
    final at = series.fetchedOn;
    if (at == null) return false;
    final now = _now();
    return at.year == now.year && at.month == now.month && at.day == now.day;
  }
}
