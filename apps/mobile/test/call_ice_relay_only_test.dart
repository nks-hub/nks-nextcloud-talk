import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine_webrtc.dart';

/// TURN is proven as far as this rig can prove it: the servers are offered and
/// relay candidates are gathered. What stays unproven is that a RELAYED pair
/// carries the media, because on a rig where both ends see each other ICE
/// picks the host pair. `--dart-define=CALL_ICE_RELAY_ONLY=true` removes the
/// host pair from the choice, which is the only way to measure that half here.
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

  test('a call relays only when it was built to', () {
    final ordinary = WebRtcCallMediaEngine.connectionConfiguration(servers);
    expect(ordinary.containsKey('iceTransportPolicy'), isFalse);

    final relayed = WebRtcCallMediaEngine.connectionConfiguration(
      servers,
      relayOnly: true,
    );
    expect(relayed['iceTransportPolicy'], 'relay');
  });

  test('the switch is off unless the build says otherwise', () {
    expect(WebRtcCallMediaEngine.relayOnly, isFalse);
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
}
