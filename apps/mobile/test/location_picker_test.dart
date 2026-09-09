import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/chat/location_picker_screen.dart';
import 'package:nextcloudtalk/features/chat/location_share_service.dart';
import 'package:nextcloudtalk/features/chat/place_search_service.dart';

import 'test_support.dart';

void main() {
  testWidgets('a typed place comes back without asking for a position', (
    tester,
  ) async {
    final host = await _openPicker(tester);

    await _enterPoint(tester, latitude: '50.0875', longitude: '14.42076');
    await tester.enterText(
      find.byKey(const Key('location-picker-name')),
      'Prague Castle',
    );
    await tester.tap(find.byKey(const Key('location-picker-confirm')));
    await tester.pumpAndSettle();

    expect(host.closed, isTrue);
    expect(host.result?.latitude, 50.0875);
    expect(host.result?.longitude, 14.42076);
    expect(host.result?.name, 'Prague Castle');
  });

  testWidgets('a denied position leaves the picked point alone', (
    tester,
  ) async {
    final host = await _openPicker(
      tester,
      overrides: <Override>[
        currentLocationSourceProvider.overrideWithValue(
          const _DenyingLocationSource(),
        ),
      ],
    );
    await _enterPoint(tester, latitude: '48.8584', longitude: '2.2945');

    await tester.tap(find.byKey(const Key('location-picker-current')));
    await tester.pumpAndSettle();

    expect(find.text('Location access was denied.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('location-picker-confirm')));
    await tester.pumpAndSettle();

    expect(host.result?.latitude, 48.8584);
    expect(host.result?.longitude, 2.2945);
    // Nothing was typed into the name field, so the room sees the same
    // wording the current-position flow sends.
    expect(host.result?.name, 'Shared location');
  });

  testWidgets('zero coordinates are refused instead of shared', (tester) async {
    final host = await _openPicker(tester);
    await _enterPoint(tester, latitude: '0', longitude: '0');

    await tester.tap(find.byKey(const Key('location-picker-confirm')));
    await tester.pumpAndSettle();

    expect(host.closed, isFalse);
    expect(host.result, isNull);
    expect(
      find.byKey(const Key('location-picker-message')),
      findsOneWidget,
      reason: 'the refusal has to say why nothing was shared',
    );
    expect(find.byKey(const Key('location-picker-confirm')), findsOneWidget);
  });

  testWidgets('an unavailable place search says so and keeps the form', (
    tester,
  ) async {
    await _openPicker(
      tester,
      overrides: <Override>[
        placeSearchSourceProvider.overrideWithValue(
          const _FailingPlaceSearch(PlaceSearchError.unavailable),
        ),
      ],
    );

    await tester.enterText(
      find.byKey(const Key('location-picker-search')),
      'Prague',
    );
    await tester.tap(find.byKey(const Key('location-picker-search-submit')));
    await tester.pumpAndSettle();

    expect(
      find.text('The place search is unavailable. Enter coordinates instead.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('location-picker-latitude')), findsOneWidget);
  });

  testWidgets('a found place fills in its point and its name', (tester) async {
    final host = await _openPicker(
      tester,
      overrides: <Override>[
        placeSearchSourceProvider.overrideWithValue(
          const _StubPlaceSearch(
            PlaceSuggestion(
              name: 'Prague Main Station',
              latitude: 50.0830,
              longitude: 14.4356,
            ),
          ),
        ),
      ],
    );

    await tester.enterText(
      find.byKey(const Key('location-picker-search')),
      'main station',
    );
    await tester.tap(find.byKey(const Key('location-picker-search-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('location-picker-result-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('location-picker-confirm')));
    await tester.pumpAndSettle();

    expect(host.result?.name, 'Prague Main Station');
    expect(host.result?.latitude, closeTo(50.0830, 0.000001));
    expect(host.result?.longitude, closeTo(14.4356, 0.000001));
  });

  testWidgets('cancelling hands back nothing at all', (tester) async {
    final host = await _openPicker(tester);
    await _enterPoint(tester, latitude: '50.0875', longitude: '14.42076');

    await tester.tap(find.byKey(const Key('location-picker-cancel')));
    await tester.pumpAndSettle();

    expect(host.closed, isTrue);
    expect(host.result, isNull);
  });

  testWidgets('the map opens blank until the background is asked for', (
    tester,
  ) async {
    await _openPicker(tester);

    expect(find.byKey(const Key('location-picker-load-map')), findsOneWidget);
    expect(find.byKey(const Key('location-picker-attribution')), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('tapping the map picks the point under the finger', (
    tester,
  ) async {
    final host = await _openPicker(tester);
    final map = find.byKey(const Key('location-picker-map'));
    final centre = tester.getCenter(map);

    // North-west of the centre, which at the opening zoom is latitude 0 and
    // longitude 0: the picked point has to move accordingly.
    await tester.tapAt(Offset(centre.dx - 40, centre.dy - 30));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('location-picker-confirm')));
    await tester.pumpAndSettle();

    expect(host.result, isNotNull);
    expect(host.result!.latitude, greaterThan(0));
    expect(host.result!.longitude, lessThan(0));
  });
}

final class _PickerHost {
  LocationPickerResult? result;
  bool closed = false;
}

Future<_PickerHost> _openPicker(
  WidgetTester tester, {
  List<Override> overrides = const <Override>[],
}) async {
  final host = _PickerHost();
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: localizedTestApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('open-picker'),
                onPressed: () async {
                  host.result = await Navigator.of(context)
                      .push<LocationPickerResult>(
                        MaterialPageRoute<LocationPickerResult>(
                          builder: (_) => const LocationPickerScreen(),
                        ),
                      );
                  host.closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-picker')));
  await tester.pumpAndSettle();
  expect(find.byType(LocationPickerScreen), findsOneWidget);
  return host;
}

Future<void> _enterPoint(
  WidgetTester tester, {
  required String latitude,
  required String longitude,
}) async {
  await tester.enterText(
    find.byKey(const Key('location-picker-latitude')),
    latitude,
  );
  await tester.enterText(
    find.byKey(const Key('location-picker-longitude')),
    longitude,
  );
  // Focusing a field scrolls the body to reveal it, and that scroll is an
  // animation: a tap dispatched while it runs lands where the button no
  // longer is.
  await tester.pumpAndSettle();
}

final class _DenyingLocationSource implements CurrentLocationSource {
  const _DenyingLocationSource();

  @override
  Future<SharedPosition> current() async {
    throw const CurrentLocationException(CurrentLocationError.permissionDenied);
  }
}

final class _FailingPlaceSearch implements PlaceSearchSource {
  const _FailingPlaceSearch(this.error);

  final PlaceSearchError error;

  @override
  Future<List<PlaceSuggestion>> search(String query) async {
    throw PlaceSearchException(error);
  }
}

final class _StubPlaceSearch implements PlaceSearchSource {
  const _StubPlaceSearch(this.suggestion);

  final PlaceSuggestion suggestion;

  @override
  Future<List<PlaceSuggestion>> search(String query) async => <PlaceSuggestion>[
    suggestion,
  ];
}
