import 'dart:convert';

import 'package:accounts_app/data/local_store.dart';
import 'package:accounts_app/data/nav_api.dart';
import 'package:accounts_app/data/nav_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _history = '''
{"meta":{"fund_house":"PPFAS Mutual Fund",
         "scheme_name":"Parag Parikh Flexi Cap Fund - Direct Plan - Growth"},
 "data":[{"date":"29-07-2026","nav":"91.01190"},
         {"date":"28-07-2026","nav":"90.55000"},
         {"date":"27-07-2026","nav":"0.00000"}],
 "status":"SUCCESS"}
''';

/// A NavApi whose history call is scripted and counted.
class _FakeApi implements NavApi {
  _FakeApi(this._build);
  final NavSeries Function() _build;
  int calls = 0;
  Object? failWith;

  @override
  Future<NavSeries> history(int code) async {
    calls++;
    final failure = failWith;
    if (failure != null) throw failure;
    return _build();
  }

  @override
  Future<List<SchemeRef>> search(String query) async => const [];
}

NavSeries _series({int code = 122639}) => NavSeries(
      code: code,
      schemeName: 'Test Fund',
      fundHouse: 'Test AMC',
      navs: {
        DateTime(2026, 7, 28): 90.55,
        DateTime(2026, 7, 29): 91.0119,
      },
    );

Future<LocalStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  return LocalStore(await SharedPreferences.getInstance());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NavApi', () {
    test('parses the history, newest last, dropping zero-NAV rows', () async {
      final api = NavApi(
          client: MockClient((_) async => http.Response(_history, 200)));
      final series = await api.history(122639);

      expect(series.schemeName, contains('Parag Parikh'));
      expect(series.fundHouse, 'PPFAS Mutual Fund');
      expect(series.navOn(DateTime(2026, 7, 29)), 91.0119);
      expect(series.latest, DateTime(2026, 7, 29));
      expect(series.earliest, DateTime(2026, 7, 28));
      // Pre-inception placeholder rows publish 0.00000 and must not become a
      // divide-by-zero in unit allotment.
      expect(series.navOn(DateTime(2026, 7, 27)), isNull);
    });

    test('a 404 names the scheme rather than the status code', () async {
      final api =
          NavApi(client: MockClient((_) async => http.Response('{}', 404)));
      await expectLater(
        api.history(999999),
        throwsA(isA<NavException>()
            .having((e) => e.message, 'message', contains('999999'))),
      );
    });

    test('an empty data list is a failure, not an empty series', () async {
      final api = NavApi(
          client: MockClient((_) async => http.Response('{"data":[]}', 200)));
      await expectLater(api.history(1), throwsA(isA<NavException>()));
    });

    test('a dead connection reports reachability', () async {
      final api = NavApi(client: MockClient((_) async => throw Exception('x')));
      await expectLater(
        api.history(1),
        throwsA(isA<NavException>()
            .having((e) => e.message, 'message', contains('Could not reach'))),
      );
    });

    test('search returns nothing rather than throwing mid-typing', () async {
      final api =
          NavApi(client: MockClient((_) async => http.Response('nope', 500)));
      expect(await api.search('parag'), isEmpty);
    });

    test('search skips queries too short to be meaningful', () async {
      var called = false;
      final api = NavApi(client: MockClient((_) async {
        called = true;
        return http.Response('[]', 200);
      }));
      expect(await api.search('pa'), isEmpty);
      expect(called, isFalse);
    });

    test('search flags direct growth plans', () async {
      final api = NavApi(client: MockClient((_) async => http.Response(
          '[{"schemeCode":122639,"schemeName":"Parag Parikh Flexi Cap Fund - '
          'Direct Plan - Growth"},'
          '{"schemeCode":122640,"schemeName":"Parag Parikh Flexi Cap Fund - '
          'Regular Plan - IDCW"}]',
          200)));
      final results = await api.search('parag parikh');
      expect(results.first.isDirect, isTrue);
      expect(results.first.isGrowth, isTrue);
      expect(results.last.isDirect, isFalse);
    });
  });

  group('NavCache', () {
    test('a second call the same day never touches the API', () async {
      final api = _FakeApi(_series);
      final cache = NavCache(
          store: await _store(),
          api: api,
          clock: () => DateTime(2026, 7, 29, 10));

      await cache.series(122639);
      await cache.series(122639);

      expect(api.calls, 1, reason: 'NAV is published once a day');
    });

    test('the next calendar day refetches', () async {
      var now = DateTime(2026, 7, 29, 23);
      final api = _FakeApi(_series);
      final cache =
          NavCache(store: await _store(), api: api, clock: () => now);

      await cache.series(122639);
      now = DateTime(2026, 7, 30, 1);
      await cache.series(122639);

      expect(api.calls, 2);
    });

    test('force refetches inside the same day', () async {
      final api = _FakeApi(_series);
      final cache = NavCache(
          store: await _store(),
          api: api,
          clock: () => DateTime(2026, 7, 29));

      await cache.series(122639);
      await cache.series(122639, force: true);

      expect(api.calls, 2);
    });

    test('a failure with a warm cache serves stale data, flagged', () async {
      var now = DateTime(2026, 7, 29);
      final api = _FakeApi(_series);
      final cache =
          NavCache(store: await _store(), api: api, clock: () => now);

      final fresh = await cache.series(122639);
      expect(fresh.isStale, isFalse);

      now = DateTime(2026, 7, 30);
      api.failWith = const NavException('Could not reach the NAV service');
      final stale = await cache.series(122639);

      expect(stale.isStale, isTrue);
      expect(stale.error, contains('Could not reach'));
      expect(stale.series.navOn(DateTime(2026, 7, 29)), 91.0119,
          reason: 'a stale valuation beats no valuation');
    });

    test('a failure with a cold cache surfaces the error', () async {
      final api = _FakeApi(_series)
        ..failWith = const NavException('Could not reach the NAV service');
      final cache = NavCache(store: await _store(), api: api);

      await expectLater(cache.series(122639), throwsA(isA<NavException>()));
    });

    test('survives an app restart by reading the stored blob', () async {
      final store = await _store();
      final first = _FakeApi(_series);
      await NavCache(
              store: store, api: first, clock: () => DateTime(2026, 7, 29))
          .series(122639);

      // A brand-new cache object, as after a cold start.
      final second = _FakeApi(_series);
      final restored = await NavCache(
              store: store, api: second, clock: () => DateTime(2026, 7, 29))
          .series(122639);

      expect(second.calls, 0);
      expect(restored.series.navOn(DateTime(2026, 7, 29)), 91.0119);
    });

    test('corrupt stored JSON is discarded and refetched', () async {
      final store = await _store();
      await store.writeNav('122639', '{not json');
      final api = _FakeApi(_series);

      final result = await NavCache(store: store, api: api).series(122639);

      expect(api.calls, 1);
      expect(result.series.navOn(DateTime(2026, 7, 29)), 91.0119);
    });

    test('peek reads the cache without any network access', () async {
      final store = await _store();
      final api = _FakeApi(_series);
      final cache = NavCache(store: store, api: api);
      await cache.series(122639);

      final peeked = NavCache(store: store, api: _FakeApi(_series))
          .peek(122639);
      expect(peeked, isNotNull);
      expect(peeked!.navOn(DateTime(2026, 7, 28)), 90.55);
    });

    test('a factory reset clears cached NAV alongside the tables', () async {
      final store = await _store();
      await store.writeNav('122639', jsonEncode(_series().toJson()));
      await store.write('investments', [
        {'id': '1'}
      ]);

      await store.clearAll();

      expect(store.readNav('122639'), isNull,
          reason: 'orphaned scheme history must not survive a reset');
      expect(store.read('investments'), isEmpty);
    });
  });
}
