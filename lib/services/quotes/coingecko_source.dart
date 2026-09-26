import 'dart:convert';

import 'package:http/http.dart' as http;

import 'quote.dart';
import 'quote_source.dart';

/// Crypto spot prices in INR from CoinGecko's free `simple/price` endpoint.
///
/// Symbols are CoinGecko ids, not tickers: `bitcoin`, not `BTC`. The endpoint
/// sends CORS headers and takes many ids per call, so a whole portfolio costs
/// one request on every platform.
class CoinGeckoSource extends QuoteSource {
  const CoinGeckoSource();

  @override
  String get name => 'CoinGecko';

  /// Ids as CoinGecko wants them: lowercase, spaces hyphenated.
  static String coinId(String symbol) =>
      symbol.trim().toLowerCase().replaceAll(' ', '-');

  @override
  Future<Quote> fetch(String symbol, http.Client client) async {
    final all = await fetchAll([symbol], client);
    final quote = all[symbol];
    if (quote == null) throw QuoteFailure(symbol, 'not listed on $name');
    return quote;
  }

  @override
  Future<Map<String, Quote>> fetchAll(
      List<String> symbols, http.Client client) async {
    if (symbols.isEmpty) return {};
    final ids = {for (final s in symbols) coinId(s): s};
    final uri = Uri.parse('https://api.coingecko.com/api/v3/simple/price'
        '?ids=${ids.keys.join(',')}&vs_currencies=inr');

    final http.Response res;
    try {
      res = await client.get(uri);
    } catch (e) {
      throw QuoteFailure(symbols.first, 'could not reach $name');
    }
    if (res.statusCode != 200) failStatus(symbols.first, res.statusCode, name);

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw QuoteFailure(symbols.first, 'unexpected response from $name');
    }

    final now = DateTime.now();
    final out = <String, Quote>{};
    for (final entry in ids.entries) {
      final price = (body[entry.key]?['inr'] as num?)?.toDouble();
      // Ids CoinGecko doesn't know are simply absent from the response. They
      // are left out here and reported per-row by the service, so one bad id
      // can't cost the rest of the batch its prices.
      if (price == null || price <= 0) continue;
      out[entry.value] = Quote(
        symbol: entry.value,
        price: price,
        asOf: now,
        source: name,
      );
    }
    return out;
  }
}

/// Gold priced per gram in INR, via the PAX Gold token — each PAXG is backed
/// by one troy ounce of London Good Delivery gold, and CoinGecko quotes it in
/// rupees, so no API key and no currency conversion are needed.
///
/// This is the *international spot* rate. Indian retail gold sells higher:
/// import duty, GST and making charges are all outside this figure. A row that
/// sets `market_price` overrides this source entirely — see [InvestmentSync].
class GoldSource extends QuoteSource {
  const GoldSource();

  static const double gramsPerTroyOunce = 31.1034768;
  static const String _paxGold = 'pax-gold';

  @override
  String get name => 'CoinGecko (PAXG spot)';

  @override
  Future<Quote> fetch(String symbol, http.Client client) async {
    const gecko = CoinGeckoSource();
    final ounce = await gecko.fetch(_paxGold, client);
    return Quote(
      symbol: symbol,
      price: ounce.price / gramsPerTroyOunce,
      asOf: ounce.asOf,
      source: name,
    );
  }

  /// Every gold row shares one rate, so a portfolio of them is still one call.
  @override
  Future<Map<String, Quote>> fetchAll(
      List<String> symbols, http.Client client) async {
    if (symbols.isEmpty) return {};
    final perGram = await fetch(symbols.first, client);
    return {
      for (final s in symbols)
        s: Quote(
          symbol: s,
          price: perGram.price,
          asOf: perGram.asOf,
          source: name,
        ),
    };
  }
}
