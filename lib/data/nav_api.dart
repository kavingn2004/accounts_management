import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'finance_repository.dart';

/// One mutual fund scheme as the search endpoint describes it.
class SchemeRef {
  const SchemeRef({required this.code, required this.name});
  final int code;
  final String name;

  /// Groww and most retail apps sell direct growth plans. A regular plan's NAV
  /// is lower by the distributor commission, so valuing a direct holding
  /// against a regular NAV understates it — the picker flags the difference.
  bool get isDirect => name.toLowerCase().contains('direct');
  bool get isGrowth => name.toLowerCase().contains('growth');

  @override
  bool operator ==(Object other) => other is SchemeRef && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// A scheme's published NAV history: date → NAV, newest date last.
///
/// Held as a sorted date list plus a map so both access patterns the math
/// needs — "the NAV on exactly this day" and "the nearest published day either
/// side" — are cheap.
class NavSeries {
  NavSeries({
    required this.code,
    required this.schemeName,
    required this.fundHouse,
    required Map<DateTime, double> navs,
    this.fetchedOn,
  })  : _navs = navs,
        dates = navs.keys.toList()..sort();

  final int code;
  final String schemeName;
  final String fundHouse;
  final Map<DateTime, double> _navs;

  /// Every date with a published NAV, oldest first.
  final List<DateTime> dates;

  /// The day this series was last downloaded, used by the cache to decide
  /// whether it is still current. Null for a series built in memory.
  final DateTime? fetchedOn;

  bool get isEmpty => dates.isEmpty;
  DateTime? get earliest => dates.isEmpty ? null : dates.first;
  DateTime? get latest => dates.isEmpty ? null : dates.last;

  double? navOn(DateTime day) => _navs[_dayOf(day)];

  Map<DateTime, double> get all => Map.unmodifiable(_navs);

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  Json toJson() => {
        'code': code,
        'scheme_name': schemeName,
        'fund_house': fundHouse,
        'fetched_on': (fetchedOn ?? DateTime.now()).toIso8601String(),
        'navs': {
          for (final e in _navs.entries) _iso.format(e.key): e.value,
        },
      };

  static NavSeries fromJson(Map<String, dynamic> json) {
    final raw = (json['navs'] as Map).cast<String, dynamic>();
    return NavSeries(
      code: (json['code'] as num).toInt(),
      schemeName: (json['scheme_name'] ?? '').toString(),
      fundHouse: (json['fund_house'] ?? '').toString(),
      fetchedOn: DateTime.tryParse((json['fetched_on'] ?? '').toString()),
      navs: {
        for (final e in raw.entries)
          DateTime.parse(e.key): (e.value as num).toDouble(),
      },
    );
  }

  static final _iso = DateFormat('yyyy-MM-dd');
}

/// Raised when NAV data cannot be fetched. Carries a message fit to show.
class NavException implements Exception {
  const NavException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Read-only client for `api.mfapi.in`, which mirrors AMFI's daily NAV
/// publication as JSON and sends `access-control-allow-origin: *` — so the web
/// build reaches it directly, with no proxy.
class NavApi {
  NavApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static const _base = 'https://api.mfapi.in';
  static final _navDate = DateFormat('dd-MM-yyyy');

  /// Schemes matching a free-text query, best-effort: a search that fails
  /// returns nothing rather than throwing, because a picker with no results is
  /// a better failure than a picker that errors mid-typing.
  Future<List<SchemeRef>> search(String query) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    try {
      final res = await _client
          .get(Uri.parse('$_base/mf/search?q=${Uri.encodeQueryComponent(q)}'));
      if (res.statusCode != 200) return const [];
      final list = jsonDecode(res.body) as List;
      return [
        for (final e in list)
          if (e is Map && e['schemeCode'] != null)
            SchemeRef(
              code: (e['schemeCode'] as num).toInt(),
              name: (e['schemeName'] ?? '').toString(),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Full NAV history for one scheme.
  ///
  /// Throws [NavException] on any failure — unlike [search], a caller here has
  /// no useful fallback and must be able to distinguish "no data" from "the
  /// network is down", so it can serve its cache instead.
  Future<NavSeries> history(int code) async {
    final http.Response res;
    try {
      res = await _client.get(Uri.parse('$_base/mf/$code'));
    } catch (_) {
      throw const NavException('Could not reach the NAV service');
    }
    if (res.statusCode == 404) {
      throw NavException('Scheme $code not found');
    }
    if (res.statusCode != 200) {
      throw NavException('NAV service returned ${res.statusCode}');
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw const NavException('Unexpected response from the NAV service');
    }

    final data = (body['data'] as List?) ?? const [];
    if (data.isEmpty) {
      throw NavException('No NAV published for scheme $code');
    }

    final navs = <DateTime, double>{};
    for (final entry in data) {
      if (entry is! Map) continue;
      final nav = double.tryParse((entry['nav'] ?? '').toString());
      if (nav == null || nav <= 0) continue; // pre-inception placeholder rows
      try {
        navs[_navDate.parse(entry['date'].toString())] = nav;
      } catch (_) {
        continue;
      }
    }
    if (navs.isEmpty) {
      throw NavException('No readable NAV for scheme $code');
    }

    final meta = (body['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    return NavSeries(
      code: code,
      schemeName: (meta['scheme_name'] ?? '').toString(),
      fundHouse: (meta['fund_house'] ?? '').toString(),
      navs: navs,
    );
  }
}
