import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/telemetry_bootstrap.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  group('scrubSentryEvent', () {
    test('drops the request, which names the server and the room', () {
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://talk.example.com/ocs/v2.php/apps/spreed/api/v4/room',
        ),
      );

      expect(scrubSentryEvent(event).request, isNull);
    });

    test('reduces a URL in the message to its scheme', () {
      final event = SentryEvent(
        message: SentryMessage(
          'GET https://talk.example.com/call/a1b2c3d4 failed',
        ),
      );

      final formatted = scrubSentryEvent(event).message!.formatted;
      expect(formatted, contains('https://<host>'));
      expect(formatted, isNot(contains('talk.example.com')));
      expect(formatted, isNot(contains('a1b2c3d4')));
    });

    test('scrubs every exception value', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'HttpException',
            value: 'Authorization: Basic fixture-value rejected',
          ),
          SentryException(
            type: 'StateError',
            value: 'room https://talk.example.com/call/a1b2c3d4 is gone',
          ),
        ],
      );

      final values = scrubSentryEvent(
        event,
      ).exceptions!.map((e) => e.value).join(' ');
      expect(values, isNot(contains('fixture-value')));
      expect(values, isNot(contains('talk.example.com')));
      expect(values, isNot(contains('a1b2c3d4')));
    });
  });

  group('scrubSentryBreadcrumb', () {
    test('scrubs the message and every string in data', () {
      final crumb = Breadcrumb(
        message: 'request to https://talk.example.com/call/a1b2c3d4',
        data: {
          'url': 'https://talk.example.com/ocs/v2.php/apps/spreed',
          'method': 'GET',
          'status_code': 404,
        },
      );

      final scrubbed = scrubSentryBreadcrumb(crumb, Hint())!;
      expect(scrubbed.message, isNot(contains('talk.example.com')));
      expect(scrubbed.data!['url'], 'https://<host>');
      expect(scrubbed.data!['method'], 'GET');
      expect(scrubbed.data!['status_code'], 404);
    });

    test('passes a null breadcrumb through', () {
      expect(scrubSentryBreadcrumb(null, Hint()), isNull);
    });
  });
}
