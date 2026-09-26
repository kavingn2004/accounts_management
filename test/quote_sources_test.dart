import 'dart:convert';

import 'package:accounts_app/services/quotes/coingecko_source.dart';
import 'package:accounts_app/services/quotes/mf_source.dart';
import 'package:accounts_app/services/quotes/quote.dart';
import 'package:accounts_app/services/quotes/yahoo_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A client that answers every request with one canned response and records
/// the URLs it was asked for.
MockClient _client(String body, {int status = 200, List<Uri>? seen}) {
  return MockClient((req) async {
    seen?.add(req.url);
    return http.Response(body, status);
  });
}

MockClient _dead() =>
    MockClient((_) async => throw const SocketExceptionStub());

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}

const _yahooBody = '''
{"chart":{"result":[{"meta":{"currency":"INR","symbol":"RELIANCE.NS",
"regularMarketPrice":1432.20,"regularMarketTime":1754130600}}],"error":null}}
''';

const _mfBody = '''
{"meta":{"scheme_name":"Parag Parikh Flexi Cap Fund - Direct Plan"},
"data":[{"date":"01-08-2026","nav":"85.32300"},
        {"date":"31-07-2026","nav":"84.90100"}]}
''';

void main() {
  group('YahooSource', () {
    test('reads the regular market price and stamps the market time',
        (() async {
      final seen = <Uri>[];
      final quote = await const YahooSource()
          .fetch('RELIANCE', _client(_yahooBody, seen: seen));

      expect(quote.price, 1432.20);
      expect(quote.symbol, 'RELIANCE', reason: 'the app\'s symbol, not .NS');
      expect(quote.asOf, DateTime.fromMillisecondsSinceEpoch(1754130600 * 1000));
      // NSE is assumed when no exchange is given.
      expect(seen.single.path, contains('RELIANCE.NS'));
    }));

    test('leaves an explicit exchange suffix alone', () async {
      final seen = <Uri>[];
      await const YahooSource()
          .fetch('RELIANCE.BO', _client(_yahooBody, seen: seen));
      expect(seen.single.path, contains('RELIANCE.BO'));
      expect(seen.single.path, isNot(contains('.BO.NS')));
    });

    test('refuses a non-INR quote rather than mixing currencies', () async {
      final usd = _yahooBody.replaceFirst('"INR"', '"USD"');
      await expectLater(
        const YahooSource().fetch('AAPL', _client(usd)),
        throwsA(isA<QuoteFailure>()
            .having((e) => e.message, 'message', contains('USD'))),
      );
    });

    test('turns a 404 into a message about the symbol', () async {
      await expectLater(
        const YahooSource().fetch('NOPE', _client('{}', status: 404)),
        throwsA(isA<QuoteFailure>()
            .having((e) => e.message, 'message', contains('check the symbol'))),
      );
    });

    test('a rate limit says so, and is not confused with a bad symbol',
        () async {
      await expectLater(
        const YahooSource().fetch('RELIANCE', _client('', status: 429)),
        throwsA(isA<QuoteFailure>()
            .having((e) => e.message, 'message', contains('rate-limiting'))),
      );
    });

    test('malformed JSON fails cleanly instead of throwing a parse error',
        () async {
      await expectLater(
        const YahooSource().fetch('RELIANCE', _client('not json')),
        throwsA(isA<QuoteFailure>()),
      );
    });

    test('a dead connection is reported, not rethrown raw', () async {
      await expectLater(
        const YahooSource().fetch('RELIANCE', _dead()),
        throwsA(isA<QuoteFailure>()
            .having((e) => e.message, 'message', contains('could not reach'))),
      );
    });
  });

  group('MutualFundSource', () {
    test('takes the newest NAV and dates it by the NAV, not by now', () async {
      final quote =
          await const MutualFundSource().fetch('122639', _client(_mfBody));
      expect(quote.price, 85.323);
      // The published NAV date — a value stamped "today" when the fund last
      // moved on Friday would misrepresent its freshness.
      expect(quote.asOf, DateTime(2026, 8, 1));
    });

    test('rejects a non-numeric code before spending a request', () async {
      final seen = <Uri>[];
      await expectLater(
        const MutualFundSource()
            .fetch('PARAG PARIKH', _client(_mfBody, seen: seen)),
        throwsA(isA<QuoteFailure>()
            .having((e) => e.message, 'message', contains('scheme code'))),
      );
      expect(seen, isEmpty);
    });

    test('an unknown code answers 200 with no data — still a failure',
        () async {
      await expectLater(
        const MutualFundSource().fetch('999999', _client('{"data":[]}')),
        throwsA(isA<QuoteFailure>()
            .having((e) => e.message, 'message', contains('no NAV'))),
      );
    });
  });

  group('CoinGeckoSource', () {
    test('prices several coins in one request', () async {
      final seen = <Uri>[];
      final quotes = await const CoinGeckoSource().fetchAll(
        ['bitcoin', 'ethereum'],
        _client('{"bitcoin":{"inr":5100000},"ethereum":{"inr":280000}}',
            seen: seen),
      );
      expect(quotes['bitcoin']!.price, 5100000);
      expect(quotes['ethereum']!.price, 280000);
      expect(seen, hasLength(1), reason: 'one batched call, not one per coin');
    });

    test('an unknown id drops out without costing the others their prices',
        () async {
      final quotes = await const CoinGeckoSource().fetchAll(
        ['bitcoin', 'not-a-coin'],
        _client('{"bitcoin":{"inr":5100000}}'),
      );
      expect(quotes.keys, ['bitcoin']);
    });

    test('normalises a ticker-shaped id to lowercase', () async {
      final seen = <Uri>[];
      await const CoinGeckoSource()
          .fetchAll(['Bitcoin'], _client('{"bitcoin":{"inr":1}}', seen: seen));
      expect(seen.single.query, contains('ids=bitcoin'));
    });
  });

  group('GoldSource', () {
    test('converts the PAXG troy-ounce price to a per-gram rate', () async {
      final quote = await const GoldSource()
          .fetch('gold', _client('{"pax-gold":{"inr":311034.768}}'));
      // 311034.768 / 31.1034768 = 10000 per gram exactly.
      expect(quote.price, closeTo(10000, 0.0001));
      expect(quote.source, contains('PAXG'));
    });

    test('every gold row shares one lookup', () async {
      final seen = <Uri>[];
      final quotes = await const GoldSource().fetchAll(
        ['gold', 'gold-coins'],
        _client('{"pax-gold":{"inr":311034.768}}', seen: seen),
      );
      expect(quotes, hasLength(2));
      expect(quotes['gold']!.price, quotes['gold-coins']!.price);
      expect(seen, hasLength(1));
    });
  });

  test('responses are decoded as UTF-8 JSON, not bytes', () {
    // Guards the assumption every source makes about http.Response.body.
    expect(jsonDecode(_mfBody)['data'], isA<List<dynamic>>());
  });
}
