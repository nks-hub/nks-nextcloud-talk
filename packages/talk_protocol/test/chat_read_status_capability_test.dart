import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('common read status capability policy', () {
    test('authenticated public policy enables the aggregate marker', () {
      final snapshot = _snapshot(
        context: CapabilityContext.authenticated,
        features: const <String>['chat-v2', 'chat-read-status'],
        readPrivacy: 0,
      );

      final profile = ChatCapabilityProfile.fromSnapshot(
        snapshot,
        federated: false,
      );

      expect(snapshot.chatReadPrivacy, ChatReadPrivacy.public);
      expect(profile.commonReadStatus, isTrue);
    });

    test('the feature list carries the marker once privacy is supplied', () {
      // `fromTalkFeatures` used to hardcode the marker off, and the chat
      // service builds every profile through it, so the aggregate read cursor
      // was never enabled on any server. `mergeChatGetResponse` then passed a
      // null `lastCommonRead` on each sync and `ChatScopeState.copyWith`
      // treats an explicit null as a clear, so the second tick appeared only
      // between setting the read marker and the very next fetch.
      const features = <String>['chat-v2', 'chat-read-status'];

      expect(
        ChatCapabilityProfile.fromTalkFeatures(
          features,
          federated: false,
          readPrivacyIsPublic: true,
        ).commonReadStatus,
        isTrue,
      );
      expect(
        ChatCapabilityProfile.fromTalkFeatures(
          features,
          federated: false,
        ).commonReadStatus,
        isFalse,
        reason: 'a caller without the account setting must not assume it',
      );
      expect(
        ChatCapabilityProfile.fromTalkFeatures(
          features,
          federated: true,
          readPrivacyIsPublic: true,
        ).commonReadStatus,
        isFalse,
        reason: 'a federated room has no aggregate marker to report',
      );
      expect(
        ChatCapabilityProfile.fromTalkFeatures(
          const <String>['chat-v2'],
          federated: false,
          readPrivacyIsPublic: true,
        ).commonReadStatus,
        isFalse,
        reason: 'the server has to support chat-read-status',
      );
    });

    test('private policy disables the aggregate marker', () {
      final snapshot = _snapshot(
        context: CapabilityContext.authenticated,
        features: const <String>['chat-v2', 'chat-read-status'],
        readPrivacy: 1,
      );

      final profile = ChatCapabilityProfile.fromSnapshot(
        snapshot,
        federated: false,
      );

      expect(snapshot.chatReadPrivacy, ChatReadPrivacy.private);
      expect(profile.commonReadStatus, isFalse);
    });

    test('missing feature fails closed even with public privacy', () {
      final profile = ChatCapabilityProfile.fromSnapshot(
        _snapshot(
          context: CapabilityContext.authenticated,
          features: const <String>['chat-v2'],
          readPrivacy: 0,
        ),
        federated: false,
      );

      expect(profile.commonReadStatus, isFalse);
    });

    test('missing privacy fails closed even with the feature', () {
      final snapshot = _snapshot(
        context: CapabilityContext.authenticated,
        features: const <String>['chat-v2', 'chat-read-status'],
      );
      final profile = ChatCapabilityProfile.fromSnapshot(
        snapshot,
        federated: false,
      );

      expect(snapshot.chatReadPrivacy, isNull);
      expect(profile.commonReadStatus, isFalse);
    });

    test('anonymous public config is not user privacy evidence', () {
      final profile = ChatCapabilityProfile.fromSnapshot(
        _snapshot(
          context: CapabilityContext.anonymous,
          features: const <String>['chat-v2', 'chat-read-status'],
          readPrivacy: 0,
        ),
        federated: false,
      );

      expect(profile.commonReadStatus, isFalse);
    });

    test('local read status is disabled for a federated room', () {
      final profile = ChatCapabilityProfile.fromSnapshot(
        _snapshot(
          context: CapabilityContext.authenticated,
          features: const <String>['chat-v2', 'chat-read-status'],
          readPrivacy: 0,
        ),
        federated: true,
      );

      expect(profile.commonReadStatus, isFalse);
    });

    test('feature-only factory cannot infer user privacy', () {
      final profile = ChatCapabilityProfile.fromTalkFeatures(const <String>[
        'chat-v2',
        'chat-read-status',
      ], federated: false);

      expect(profile.commonReadStatus, isFalse);
    });
  });

  group('read privacy validation', () {
    for (final invalid in <Object?>[-1, 2, true, '0', 0.0]) {
      test(
        'rejects unsupported wire value ${invalid.runtimeType}:$invalid',
        () {
          expect(
            () => _snapshot(
              context: CapabilityContext.authenticated,
              features: const <String>['chat-read-status'],
              readPrivacy: invalid,
            ),
            throwsA(
              isA<TalkProtocolException>()
                  .having(
                    (error) => error.code,
                    'code',
                    TalkProtocolErrorCode.invalidCapabilities,
                  )
                  .having(
                    (error) => error.path,
                    'path',
                    r'$.ocs.data.capabilities.spreed.config.chat.read-privacy',
                  ),
            ),
          );
        },
      );
    }

    test('rejects a non-object chat config', () {
      expect(
        () => _snapshot(
          context: CapabilityContext.authenticated,
          features: const <String>['chat-read-status'],
          chatConfig: const <Object?>[],
        ),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.code,
            'code',
            TalkProtocolErrorCode.invalidCapabilities,
          ),
        ),
      );
    });
  });

  group('typing privacy validation', () {
    test('parses public and private authenticated policies', () {
      expect(
        _snapshot(
          context: CapabilityContext.authenticated,
          features: const <String>['signaling-v3', 'typing-privacy'],
          typingPrivacy: 0,
        ).chatTypingPrivacy,
        ChatTypingPrivacy.public,
      );
      expect(
        _snapshot(
          context: CapabilityContext.authenticated,
          features: const <String>['signaling-v3', 'typing-privacy'],
          typingPrivacy: 1,
        ).chatTypingPrivacy,
        ChatTypingPrivacy.private,
      );
    });

    test('keeps a missing policy unknown instead of assuming public', () {
      expect(
        _snapshot(
          context: CapabilityContext.authenticated,
          features: const <String>['signaling-v3', 'typing-privacy'],
        ).chatTypingPrivacy,
        isNull,
      );
    });

    for (final invalid in <Object?>[-1, 2, true, '0', 0.0]) {
      test('rejects typing privacy ${invalid.runtimeType}:$invalid', () {
        expect(
          () => _snapshot(
            context: CapabilityContext.authenticated,
            features: const <String>['typing-privacy'],
            typingPrivacy: invalid,
          ),
          throwsA(
            isA<TalkProtocolException>()
                .having(
                  (error) => error.code,
                  'code',
                  TalkProtocolErrorCode.invalidCapabilities,
                )
                .having(
                  (error) => error.path,
                  'path',
                  r'$.ocs.data.capabilities.spreed.config.chat.typing-privacy',
                ),
          ),
        );
      });
    }
  });
}

CapabilitySnapshot _snapshot({
  required CapabilityContext context,
  required List<String> features,
  Object? readPrivacy = _missing,
  Object? typingPrivacy = _missing,
  Object? chatConfig = _missing,
}) {
  final resolvedChatConfig = switch (chatConfig) {
    _Missing() => <String, Object?>{
      if (readPrivacy is! _Missing) 'read-privacy': readPrivacy,
      if (typingPrivacy is! _Missing) 'typing-privacy': typingPrivacy,
    },
    _ => chatConfig,
  };
  return CapabilitySnapshot.fromJson(<String, Object?>{
    'ocs': <String, Object?>{
      'meta': <String, Object?>{
        'status': 'ok',
        'statuscode': 200,
        'message': 'OK',
      },
      'data': <String, Object?>{
        'version': <String, Object?>{
          'major': 34,
          'minor': 0,
          'micro': 1,
          'string': '34.0.1',
          'edition': '',
          'extendedSupport': false,
        },
        'capabilities': <String, Object?>{
          'spreed': <String, Object?>{
            'features': <Object?>[...features],
            'config': <String, Object?>{'chat': resolvedChatConfig},
            'version': '24.0.2',
          },
        },
      },
    },
  }, context: context);
}

const _missing = _Missing();

final class _Missing {
  const _Missing();
}
