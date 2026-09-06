import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_controls.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';

import 'test_support.dart';

void main() {
  const roomKey = (accountId: 'account-a', roomToken: 'rooma123');
  const recordingKey = Key('call-banner-recording');

  Widget controls(CallJoinState join) {
    return ProviderScope(
      child: localizedTestApp(
        home: Scaffold(
          body: CallControls(roomKey: roomKey, join: join, color: Colors.white),
        ),
      ),
    );
  }

  testWidgets(
    'the recording control appears for a moderator on a server that '
    'advertises recording-v1',
    (tester) async {
      await tester.pumpWidget(
        controls(
          const CallJoinState(
            phase: CallJoinPhase.joined,
            canManageRecording: true,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(recordingKey), findsOneWidget);
    },
  );

  testWidgets(
    'the recording control is absent for a plain participant',
    (tester) async {
      await tester.pumpWidget(
        controls(const CallJoinState(phase: CallJoinPhase.joined)),
      );
      await tester.pump();

      expect(find.byKey(recordingKey), findsNothing);
    },
  );

  testWidgets(
    'an active recording shows the stop label and a selected icon',
    (tester) async {
      await tester.pumpWidget(
        controls(
          const CallJoinState(
            phase: CallJoinPhase.joined,
            canManageRecording: true,
            recordingActive: true,
          ),
        ),
      );
      await tester.pump();

      final button = tester.widget<IconButton>(find.byKey(recordingKey));
      expect(button.isSelected, isTrue);
      expect(button.tooltip, 'Stop recording');
    },
  );

  testWidgets(
    'an inactive recording shows the start label and an unselected icon',
    (tester) async {
      await tester.pumpWidget(
        controls(
          const CallJoinState(
            phase: CallJoinPhase.joined,
            canManageRecording: true,
          ),
        ),
      );
      await tester.pump();

      final button = tester.widget<IconButton>(find.byKey(recordingKey));
      expect(button.isSelected, isFalse);
      expect(button.tooltip, 'Start recording');
    },
  );
}
