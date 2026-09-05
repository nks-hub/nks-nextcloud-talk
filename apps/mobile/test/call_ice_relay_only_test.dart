import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine_webrtc.dart';
import 'package:nextcloudtalk/features/settings/call_relay_preference.dart';

/// The relay servers themselves are never configured in the app or in the
/// build — Talk hands them out per room in its signalling settings, from what
/// the Nextcloud administrator entered there. What this covers is the
/// transport POLICY applied to them: with "always use a relay server" on, the
/// host candidates are gone from the choice, so a call that connects at all
/// connected through TURN. That is the only way to measure the relay path on
/// a rig where a direct connection would always win.
void main() {
  const servers = [
    CallIceServer(
      urls: ['stun:stun.example.invalid:3478'],
      username: null,
      credential: null,
    ),
    CallIceServer(
      urls: ['turn:turn.example.invalid:3478'],
      username: 'user',
      credential: 'secret',
    ),
  ];

  test('a call relays only when the policy says so', () {
    final ordinary = WebRtcCallMediaEngine.connectionConfiguration(servers);
    expect(ordinary.containsKey('iceTransportPolicy'), isFalse);

    final relayed = WebRtcCallMediaEngine.connectionConfiguration(
      servers,
      relayOnly: true,
    );
    expect(relayed['iceTransportPolicy'], 'relay');
  });

  test('an engine relays only when it was asked to', () {
    expect(const WebRtcCallMediaEngine().relayOnly, isFalse);
    expect(const WebRtcCallMediaEngine(relayOnly: true).relayOnly, isTrue);
  });

  test('every server keeps its credentials on the way to the plugin', () {
    final configuration = WebRtcCallMediaEngine.connectionConfiguration(
      servers,
    );
    final ice = configuration['iceServers'] as List<dynamic>;
    expect(ice, hasLength(2));
    expect((ice.first as Map)['urls'], ['stun:stun.example.invalid:3478']);
    expect((ice.first as Map).containsKey('username'), isFalse);
    expect((ice.last as Map)['username'], 'user');
    expect((ice.last as Map)['credential'], 'secret');
    expect(configuration['sdpSemantics'], 'unified-plan');
  });

  test('the choice survives a restart, and defaults to off', () async {
    final directory = Directory.systemTemp.createTempSync('call-relay');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = FileCallRelayPreferenceStore(directory: directory);

    expect(await store.read(), isFalse);
    await store.write(true);
    expect(await FileCallRelayPreferenceStore(directory: directory).read(),
        isTrue);
    await store.write(false);
    expect(await store.read(), isFalse);
  });
}
