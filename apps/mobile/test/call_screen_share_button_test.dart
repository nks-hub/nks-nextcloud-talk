import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_session.dart';
import 'package:nextcloudtalk/features/calls/call_screen_share_button.dart';
import 'package:nextcloudtalk/features/calls/call_screen_source_picker.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';

import 'test_support.dart';

const _room = (accountId: 'account-a', roomToken: 'rooma123');
const _source = CallScreenSource(
  id: 'window-1',
  name: 'Document window',
  isWindow: true,
);

void main() {
  Future<void> mount(
    WidgetTester tester,
    _ShareController controller,
    _SourcesEngine engine,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          callJoinControllerProvider.overrideWith(() => controller),
          callMediaEngineProvider.overrideWithValue(engine),
        ],
        child: localizedTestApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => CallScreenShareButton(
                roomKey: _room,
                join: ref.watch(callJoinControllerProvider(_room)),
                color: Colors.blue,
                buttonKey: const Key('share-button'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the control forwards the confirmed source to the controller', (
    tester,
  ) async {
    final controller = _ShareController();
    await mount(tester, controller, _SourcesEngine());
    await tester.tap(find.byKey(const Key('share-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_source.name));
    await tester.pumpAndSettle();
    expect(controller.selected, isNull);
    await tester.tap(find.byKey(const Key('call-screen-source-confirm')));
    await tester.pumpAndSettle();
    expect(controller.selected?.id, _source.id);
  });

  testWidgets('a cancelled picker releases the busy control', (tester) async {
    final controller = _ShareController();
    final loaded = Completer<List<CallScreenSource>>();
    await mount(tester, controller, _SourcesEngine(pending: loaded.future));
    await tester.tap(find.byKey(const Key('share-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('share-button')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('share-button')))
          .onPressed,
      isNotNull,
    );
    expect(controller.selected, isNull);
    loaded.complete([_source]);
    await tester.pump();
  });

  testWidgets('a capture failure is visible and the control can be retried', (
    tester,
  ) async {
    final controller = _ShareController()
      ..failure = CallMediaError.screenShareUnavailable;
    await mount(tester, controller, _SourcesEngine());
    await tester.tap(find.byKey(const Key('share-button')));
    await tester.pumpAndSettle();
    expect(
      find.text('The action could not be completed. Please try again.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('share-button')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('ending the call dismisses an open picker without a source', (
    tester,
  ) async {
    final controller = _ShareController();
    await mount(tester, controller, _SourcesEngine());
    await tester.tap(find.byKey(const Key('share-button')));
    await tester.pumpAndSettle();
    expect(find.byType(CallScreenSourcePicker), findsOneWidget);
    controller.finishCall();
    await tester.pumpAndSettle();
    expect(find.byType(CallScreenSourcePicker), findsNothing);
    expect(controller.selected, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stopping an existing share does not enumerate sources', (
    tester,
  ) async {
    final controller = _ShareController(sharing: true);
    final engine = _SourcesEngine();
    await mount(tester, controller, engine);
    await tester.tap(find.byKey(const Key('share-button')));
    await tester.pumpAndSettle();
    expect(controller.requestedSharing, isFalse);
    expect(engine.enumerations, 0);
    expect(find.byType(CallScreenSourcePicker), findsNothing);
  });
}

final class _SourcesEngine extends Fake implements CallMediaEngine {
  _SourcesEngine({this.pending});

  final Future<List<CallScreenSource>>? pending;
  int enumerations = 0;

  @override
  Future<List<CallScreenSource>> screenSources() {
    enumerations++;
    return pending ?? Future.value([_source]);
  }
}

final class _ShareController extends CallJoinController {
  _ShareController({this.sharing = false});

  final bool sharing;
  CallScreenSource? selected;
  CallMediaError? failure;
  bool? requestedSharing;

  @override
  CallJoinState build(CallRoomKey arg) => CallJoinState(
    phase: CallJoinPhase.joined,
    media: CallMediaState(
      phase: CallMediaPhase.connected,
      screenSharing: sharing,
    ),
  );

  @override
  Future<CallMediaError?> setScreenSharing(
    bool sharing, {
    Future<CallScreenSource?> Function()? chooseSource,
  }) async {
    requestedSharing = sharing;
    if (failure != null) return failure;
    if (sharing) selected = await chooseSource!();
    return null;
  }

  void finishCall() => state = const CallJoinState();
}
