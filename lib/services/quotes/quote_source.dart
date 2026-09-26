import 'package:http/http.dart' as http;

import 'quote.dart';

/// Where prices come from for one family of instruments.
///
/// Each implementation does one thing: symbol in, [Quote] out, or a
/// [QuoteFailure] describing why not. No caching, no throttling, no knowledge
/// of investment rows — [QuoteService] owns all of that, which is what keeps
/// these testable against a fake client and a recorded response.
abstract class QuoteSource {
  const QuoteSource();

  /// Label used in messages and on the row ("Yahoo Finance", "AMFI via mfapi").
  String get name;

  /// Whether this source can be reached from the current platform. A browser
  /// cannot call a host that sends no CORS headers, and no amount of retrying
  /// changes that, so the service asks first rather than failing repeatedly.
  bool get availableHere => true;

  /// Fetch one symbol. Throws [QuoteFailure] — never a raw transport error.
  Future<Quote> fetch(String symbol, http.Client client);

  /// Fetch many at once. Sources with a batch endpoint override this; the
  /// default is honest sequential fetching so every source supports the same
  /// call shape.
  Future<Map<String, Quote>> fetchAll(
      List<String> symbols, http.Client client) async {
    final out = <String, Quote>{};
    for (final s in symbols) {
      out[s] = await fetch(s, client);
    }
    return out;
  }
}

/// Shared response handling: anything that isn't a 200 becomes a [QuoteFailure]
/// worded for a person, so no screen ever shows a bare status code.
Never failStatus(String symbol, int status, String sourceName) {
  final message = switch (status) {
    404 => 'not found on $sourceName — check the symbol',
    429 => '$sourceName is rate-limiting; try again shortly',
    >= 500 => '$sourceName is unavailable right now',
    _ => '$sourceName returned $status',
  };
  throw QuoteFailure(symbol, message);
}
