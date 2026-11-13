import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

CapabilitySnapshot _snapshot({
  List<String> talkFeatures = const ['chat-reference-id', 'silent-send'],
  bool extension = true,
  CapabilityContext context = CapabilityContext.authenticated,
}) => CapabilitySnapshot.fromJson({
  'ocs': {
    'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
    'data': {
      'version': {
        'major': 34,
        'minor': 0,
        'micro': 1,
        'string': '34.0.1',
        'edition': '',
        'extendedSupport': false,
      },
      'capabilities': {
        'spreed': {'features': talkFeatures},
        if (extension)
          'owntalk_extensions': {
            'version': '0.4.0',
            'api': 1,
            'features': ['appearance.colors'],
            'acl': 'roles',
            'roomTypes': ['one2one', 'group', 'public'],
          },
      },
    },
  },
}, context: context);

OwnTalkAppearanceNoticeRequest _request({
  CapabilitySnapshot? capabilities,
  int revision = 7,
  String message = 'The look changed',
}) => OwnTalkAppearanceNoticeRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: ConversationToken.parse('abc123xy', path: r'$.roomToken'),
  capabilities: capabilities ?? _snapshot(),
  revision: revision,
  message: message,
);

void main() {
  group('OwnTalkAppearanceNoticeRequest', () {
    test('posts a silent message with the marker as referenceId', () {
      final request = _request();
      expect(request.httpMethod, 'POST');
      expect(
        request.uri.toString(),
        'https://cloud.example.invalid/ocs/v2.php/apps/spreed/api/v1/chat/'
        'abc123xy?format=json',
      );
      expect(request.formBody, {
        'message': 'The look changed',
        'referenceId': 'owntalk-appearance-7',
        'silent': 'true',
      });
      expect(request.headers['OCS-APIRequest'], 'true');
    });

    test('the marker fits Talk and is recognised as a marker', () {
      final id = _request(revision: 0x7fffffff).referenceId;
      expect(id.length, lessThanOrEqualTo(64));
      expect(isOwnTalkAppearanceReferenceId(id), isTrue);
      expect(isOwnTalkAppearanceReferenceId('owntalk-appearance-'), isTrue);
      expect(isOwnTalkAppearanceReferenceId('1b4e28ba-2fa1-41d2-883f'), isFalse);
      expect(isOwnTalkAppearanceReferenceId(''), isFalse);
    });

    test('is refused without the extension', () {
      expect(
        () => _request(capabilities: _snapshot(extension: false)),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('is refused when Talk cannot send silently, so nobody is pinged', () {
      expect(
        () => _request(
          capabilities: _snapshot(talkFeatures: const ['chat-reference-id']),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(
        () => _request(
          capabilities: _snapshot(talkFeatures: const ['silent-send']),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    });

    test('is refused for an unauthenticated snapshot, a bad revision or text', () {
      expect(
        () => _request(
          capabilities: _snapshot(context: CapabilityContext.anonymous),
        ),
        throwsA(isA<TalkProtocolException>()),
      );
      expect(() => _request(revision: -1), throwsA(isA<TalkProtocolException>()));
      expect(() => _request(message: '  '), throwsA(isA<TalkProtocolException>()));
    });
  });
}
