import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'quote.dart';
import 'quote_source.dart';

/// Mutual fund and SIP NAV by AMFI scheme code, via mfapi.in.
///
/// AMFI publishes the authoritative figures as one ~7MB `NAVAll.txt` dump;
/// mfapi.in serves the same numbers one scheme at a time as small JSON and
/// sends CORS headers, so a fund refreshes on web as well as on a phone.
///
/// NAV is declared once a day (~11pm IST), so [Quote.asOf] carries the NAV's
/// own date rather than the fetch time — a value stamped "today" when the
/// fund last moved on Friday would be a lie.
class MutualFundSource extends QuoteSource {
  const MutualFundSource();

  @override
  String get name => 'AMFI (mfapi.in)';

  static final _navDate = DateFormat('dd-MM-yyyy');

  @override
  Future<Quote> fetch(String symbol, http.Client client) async {
    final code = symbol.trim();
    if (int.tryParse(code) == null) {
      throw QuoteFailure(
          symbol, 'not an AMFI scheme code — expected digits, e.g. 120503');
    }
    final uri = Uri.parse('https://api.mfapi.in/mf/$code');

    final http.Response res;
    try {
      res = await client.get(uri);
    } catch (e) {
      throw QuoteFailure(symbol, 'could not reach $name');
    }
    if (res.statusCode != 200) failStatus(symbol, res.statusCode, name);

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw QuoteFailure(symbol, 'unexpected response from $name');
    }

    // mfapi answers an unknown code with 200 and an empty data list.
    final data = (body['data'] as List?) ?? const [];
    if (data.isEmpty) {
      throw QuoteFailure(symbol, 'no NAV published for scheme $code');
    }

    final latest = data.first as Map<String, dynamic>;
    final nav = double.tryParse((latest['nav'] ?? '').toString());
    if (nav == null || nav <= 0) {
      throw QuoteFailure(symbol, 'unreadable NAV for scheme $code');
    }

    DateTime asOf;
    try {
      asOf = _navDate.parse(latest['date'].toString());
    } catch (_) {
      asOf = DateTime.now();
    }

    return Quote(symbol: symbol, price: nav, asOf: asOf, source: name);
  }
}
