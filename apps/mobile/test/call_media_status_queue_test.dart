import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine_webrtc.dart';

void main() {
  test('pending status frames stay bounded until the channel opens', () {
    final messages = <({String type, Object? payload})>[];
    for (var index = 0; index < 400; index++) {
      messages
        ..add((
          type: index.isEven ? 'speaking' : 'stoppedSpeaking',
          payload: null,
        ))
        ..add((type: index.isEven ? 'audioOn' : 'audioOff', payload: null))
        ..add((type: index.isEven ? 'videoOn' : 'videoOff', payload: null));
    }
    for (var index = 0; index < 40; index++) {
      messages.add((type: 'custom-$index', payload: index));
    }

    final flushed = compactWebRtcStatusFramesForTesting(messages)
        .map((frame) => jsonDecode(frame) as Map<String, dynamic>)
        .toList(growable: false);

    expect(flushed, hasLength(19));
    expect(flushed.take(3).map((frame) => frame['type']), <String>[
      'stoppedSpeaking',
      'audioOff',
      'videoOff',
    ]);
    expect(flushed.skip(3).map((frame) => frame['type']), <String>[
      for (var index = 24; index < 40; index++) 'custom-$index',
    ]);
    expect(flushed.skip(3).map((frame) => frame['payload']), <int>[
      for (var index = 24; index < 40; index++) index,
    ]);
  });

  test('replacing a state moves its last change to the end', () {
    final flushed =
        compactWebRtcStatusFramesForTesting(<({String type, Object? payload})>[
          (type: 'audioOn', payload: null),
          (type: 'videoOn', payload: null),
          (type: 'custom', payload: 1),
          (type: 'audioOff', payload: null),
        ]).map((frame) => jsonDecode(frame) as Map<String, dynamic>);

    expect(flushed.map((frame) => frame['type']), <String>[
      'videoOn',
      'custom',
      'audioOff',
    ]);
  });
}
