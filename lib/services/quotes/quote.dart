/// One fetched unit price, always in INR.
///
/// A quote is a reading, not a holding: it says what one share / unit / coin /
/// gram is worth and when that was true. Turning it into a row's value is
/// [InvestmentSync]'s job, because only the row knows how much is held.
class Quote {
  const Quote({
    required this.symbol,
    required this.price,
    required this.asOf,
    required this.source,
  });

  /// The symbol as the app stores it (not the vendor's mangled form — the
  /// `.NS` Yahoo needs is an implementation detail of that source).
  final String symbol;

  /// Price of one unit in INR.
  final double price;

  /// When the price was fetched. Sources that publish an official timestamp
  /// (mutual fund NAV dates) use theirs; the rest use the fetch time.
  final DateTime asOf;

  /// Human-readable origin, shown to the user so a figure is never anonymous.
  final String source;
}

/// A quote that could not be fetched, carrying a message fit to show a user.
///
/// Every failure is per-symbol and non-fatal: the stored value stands and the
/// row keeps whatever it last knew. [unsupportedOnPlatform] marks the one
/// failure that will never succeed by retrying — a browser calling a host that
/// sends no CORS headers — so the UI can say so instead of blaming the network.
class QuoteFailure implements Exception {
  const QuoteFailure(
    this.symbol,
    this.message, {
    this.unsupportedOnPlatform = false,
  });

  final String symbol;
  final String message;
  final bool unsupportedOnPlatform;

  @override
  String toString() => '$symbol: $message';
}
