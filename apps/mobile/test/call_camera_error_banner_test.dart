import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_banner.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';

import 'test_support.dart';

void main() {
  for (final language in ['en', 'cs']) {
    for (final denied in [true, false]) {
      testWidgets(
        'camera failure keeps the call active ($language, denied: $denied)',
        (tester) async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                callLifecyclePersistedProvider.overrideWith(
                  (ref, key) async => false,
                ),
                callJoinControllerProvider.overrideWith(
                  () => _JoinedCameraFailure(
                    denied
                        ? CallMediaError.cameraPermissionDenied
                        : CallMediaError.cameraUnavailable,
                  ),
                ),
              ],
              child: localizedTestApp(
                locale: Locale(language),
                home: const Scaffold(
                  body: OngoingCallBanner(
                    account: _account,
                    conversation: _room,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final expected = language == 'cs'
              ? (denied
                    ? 'Přístup ke kameře nebyl povolen. Hovor pokračuje bez videa.'
                    : 'Kameru se nepodařilo spustit. Hovor pokračuje bez videa.')
              : (denied
                    ? 'Camera access was not granted. The call continues without video.'
                    : 'The camera could not be started. The call continues without video.');
          expect(find.text(expected), findsOneWidget);
          final leave = tester.widget<FilledButton>(
            find.byKey(const Key('call-banner-join')),
          );
          expect(leave.onPressed, isNotNull);
        },
      );
    }
  }
}

final class _JoinedCameraFailure extends CallJoinController {
  _JoinedCameraFailure(this.error);
  final CallMediaError error;
  @override
  CallJoinState build(CallRoomKey arg) =>
      CallJoinState(phase: CallJoinPhase.joined, mediaError: error);
}

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 0,
);

const _room = CachedConversation(
  accountId: 'account-a',
  token: 'rooma123',
  displayName: 'Room',
  description: '',
  lastActivity: 0,
  unreadMessages: 0,
  favorite: false,
  isArchived: false,
  readOnly: 0,
  roomType: 2,
  roomName: 'Room',
  objectType: '',
  avatarVersion: '',
  isCustomAvatar: false,
  rawJson: '{"hasCall":false}',
);
