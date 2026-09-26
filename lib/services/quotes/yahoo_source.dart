import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'quote.dart';
import 'quote_source.dart';

/// Indian listed equity via Yahoo Finance's chart endpoint. Free, no key.
///
/// Yahoo sends no `Access-Control-Allow-Origin`, so a browser can never call
/// it. [availableHere] says so up front and the web build reports "stock
/// prices need the mobile app" instead of retrying a request the browser will
/// keep refusing.
class YahooSource extends QuoteSource {
  const YahooSource();

  @override
  String get name => 'Yahoo Finance';

  @override
  bool get availableHere => !kIsWeb;

  /// NSE is the default exchange: a bare `RELIANCE` means `RELIANCE.NS`. An
  /// explicit suffix (`.BO` for BSE, or a foreign listing) is left alone.
  static String yahooSymbol(String symbol) {
    final s = symbol.trim().toUpperCase();
    return s.contains('.') ? s : '$s.NS';
  }

  @override
  Future<Quote> fetch(String symbol, http.Client client) async {
    final ticker = yahooSymbol(symbol);
    final uri = Uri.parse('https://query1.finance.yahoo.com/v8/finance/chart/'
        '$ticker?interval=1d&range=1d');

    final http.Response res;
    try {
      res = await client.get(uri);
    } catch (e) {
      throw QuoteFailure(symbol, 'could not reach $name');
    }
    if (res.statusCode != 200) failStatus(symbol, res.statusCode, name);

    final Map<String, dynamic> meta;
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final results = (body['chart']?['result'] as List?) ?? const [];
      if (results.isEmpty) throw const FormatException('no result');
      meta = (results.first as Map<String, dynamic>)['meta']
          as Map<String, dynamic>;
    } catch (_) {
      throw QuoteFailure(symbol, 'unexpected response from $name');
    }

    final price = (meta['regularMarketPrice'] as num?)?.toDouble();
    if (price == null || price <= 0) {
      throw QuoteFailure(symbol, 'no price quoted for $ticker');
    }

    // A holding valued in rupees cannot be priced off a dollar quote, and
    // silently mixing the two would corrupt net worth. Refuse instead.
    final currency = (meta['currency'] ?? 'INR').toString().toUpperCase();
    if (currency != 'INR') {
      throw QuoteFailure(symbol, 'quoted in $currency, not INR');
    }

    final epoch = (meta['regularMarketTime'] as num?)?.toInt();
    return Quote(
      symbol: symbol,
      price: price,
      asOf: epoch == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(epoch * 1000),
      source: name,
    );
  }
}
