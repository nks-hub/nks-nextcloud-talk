import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/features/chat/place_search_service.dart';

void main() {
  test('a submitted name is asked of Nominatim once, identified', () async {
    final requests = <http.BaseRequest>[];
    final search = NominatimPlaceSearch(
      client: MockClient((request) async {
        requests.add(request);
        return _results([
          {
            'lat': '50.0875',
            'lon': '14.42076',
            'display_name': 'Old Town Square, Prague',
          },
        ]);
      }),
    );

    final suggestions = await search.search('  old town square  ');

    expect(requests.single.url.host, 'nominatim.openstreetmap.org');
    expect(requests.single.url.path, '/search');
    expect(requests.single.url.queryParameters['q'], 'old town square');
    expect(requests.single.url.queryParameters['format'], 'jsonv2');
    expect(requests.single.url.queryParameters['limit'], '5');
    // The usage policy requires a User-Agent that names the application.
    expect(
      requests.single.headers['User-Agent'],
      contains('com.nkshub.nextcloudtalk'),
    );
    expect(suggestions.single.name, 'Old Town Square, Prague');
    expect(suggestions.single.latitude, 50.0875);
    expect(suggestions.single.longitude, 14.42076);
  });

  test('no more than five places come back', () async {
    final search = NominatimPlaceSearch(
      client: MockClient(
        (request) async => _results(
          List.generate(
            9,
            (index) => <String, Object?>{
              'lat': '${index + 1}',
              'lon': '${index + 1}',
              'display_name': 'Place $index',
            },
          ),
        ),
      ),
    );

    expect((await search.search('place')).length, 5);
  });

  test('an entry without a usable point is dropped', () async {
    final search = NominatimPlaceSearch(
      client: MockClient(
        (request) async => _results([
          {'lat': '91.0', 'lon': '0.0', 'display_name': 'Off the globe'},
          {'lat': 'not a number', 'lon': '0.0', 'display_name': 'Unparsed'},
          {'lat': '10.0', 'lon': '20.0', 'display_name': '   '},
          {'lat': '10.0', 'lon': '20.0', 'display_name': 'Usable'},
        ]),
      ),
    );

    final suggestions = await search.search('place');

    expect(suggestions.map((suggestion) => suggestion.name), <String>[
      'Usable',
    ]);
  });

  test('nothing usable in the answer reads as no results', () async {
    final search = NominatimPlaceSearch(
      client: MockClient((request) async => _results(const [])),
    );

    await expectLater(
      search.search('nowhere'),
      throwsA(
        isA<PlaceSearchException>().having(
          (error) => error.code,
          'code',
          PlaceSearchError.noResults,
        ),
      ),
    );
  });

  test('an error page answered with 200 is not a result list', () async {
    final search = NominatimPlaceSearch(
      client: MockClient(
        (request) async => http.Response(
          '<html>rate limited</html>',
          200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      search.search('prague'),
      throwsA(
        isA<PlaceSearchException>().having(
          (error) => error.code,
          'code',
          PlaceSearchError.unavailable,
        ),
      ),
    );
  });

  test('a server failure is unavailable, not an empty answer', () async {
    final search = NominatimPlaceSearch(
      client: MockClient(
        (request) async => http.Response(
          'busy',
          503,
          headers: const {'content-type': 'application/json'},
        ),
      ),
    );

    await expectLater(
      search.search('prague'),
      throwsA(
        isA<PlaceSearchException>().having(
          (error) => error.code,
          'code',
          PlaceSearchError.unavailable,
        ),
      ),
    );
  });

  test('a second search in the same second is refused, not sent', () async {
    var calls = 0;
    final search = NominatimPlaceSearch(
      client: MockClient((request) async {
        calls++;
        return _results([
          {'lat': '1.0', 'lon': '2.0', 'display_name': 'Somewhere'},
        ]);
      }),
    );

    await search.search('first');
    await expectLater(
      search.search('second'),
      throwsA(
        isA<PlaceSearchException>().having(
          (error) => error.code,
          'code',
          PlaceSearchError.rateLimited,
        ),
      ),
    );

    expect(calls, 1, reason: 'one request a second is what the policy allows');
  });

  test('a name is trimmed to what a share request accepts', () {
    expect(sanitizedLocationName('  Prague Castle  '), 'Prague Castle');
    // The share request refuses a control character outright.
    expect(sanitizedLocationName('Prague\u0007Castle'), 'Prague Castle');
    expect(sanitizedLocationName('   '), isNull);
    expect(sanitizedLocationName(42), isNull);
    expect(sanitizedLocationName('x' * 300)!.length, 256);
  });
}

http.Response _results(List<Map<String, Object?>> entries) => http.Response(
  jsonEncode(entries),
  200,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
