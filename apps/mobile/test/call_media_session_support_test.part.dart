part of 'call_media_session_test.dart';

CallSignalingUpdate _update({
  required String? localPeerId,
  List<SignalingParticipant> participants = const [],
  List<SignalingPeerMessage> messages = const [],
  SignalingTopology topology = SignalingTopology.externalPeerToPeer,
  SignalingTransportKind transport = SignalingTransportKind.externalHpb,
  SignalingAccountPhase phase = SignalingAccountPhase.signalingReady,
  bool roomConfirmed = true,
  bool renegotiationRequired = false,
  int roomEpoch = 1,
}) => CallSignalingUpdate(
  key: const (accountId: 'account-a', roomToken: 'rooma123'),
  outcome: SignalingRuntimeOutcome.unchanged,
  phase: phase,
  transport: transport,
  topology: topology,
  participants: participants,
  roomConfirmed: roomConfirmed,
  federationInterrupted: false,
  renegotiationRequired: renegotiationRequired,
  messages: messages,
  controls: const <HpbControlMessage>[],
  chatRelay: null,
  roomEpoch: roomEpoch,
  chatRelaySupported: false,
  localPeerId: localPeerId == null ? null : SignalingPeerId.parse(localPeerId),
  iceServers: <IceServerConfiguration>[
    IceServerConfiguration(
      urls: const ['stun:stun.example.invalid:19302'],
      username: null,
      credential: null,
    ),
  ],
  failure: null,
);

SignalingParticipant _participant(String peerId, {int inCall = 7}) =>
    SignalingParticipant(
      peerId: SignalingPeerId.parse(peerId),
      nextcloudSessionId: null,
      userId: 'user-$peerId',
      inCall: inCall,
      permissions: 255,
      actorType: 'users',
      actorId: 'user-$peerId',
      federated: false,
      features: const <String>[],
    );

SignalingPeerMessage _message(
  String sender,
  String type,
  Map<String, Object?> payload, {
  String? sid,
  String roomType = 'video',
}) => SignalingPeerMessage(
  type: type,
  roomType: roomType,
  sid: sid,
  recipient: SignalingPeerId.parse(_local),
  sender: SignalingPeerId.parse(sender),
  payload: SignalingOpaquePayload.fromJson(payload),
);

final class _FakeInterruptions implements CallAudioInterruptions {
  _FakeInterruptions(this.events);

  @override
  final Stream<CallAudioInterruption> events;
}

final class _FakeEngine implements CallMediaEngine {
  int microphoneOpens = 0;
  CallMediaError? connectionError;
  CallMediaError? microphoneError;
  final List<_FakeAudio> audio = <_FakeAudio>[];
  final List<_FakeConnection> connections = <_FakeConnection>[];

  @override
  Future<CallLocalAudio> openMicrophone() async {
    final error = microphoneError;
    if (error != null) {
      throw CallMediaException(error);
    }
    microphoneOpens++;
    final opened = _FakeAudio();
    audio.add(opened);
    return opened;
  }

  CallMediaError? cameraError;
  final List<_FakeVideo> cameras = <_FakeVideo>[];

  CallMediaError? screenError;
  final List<_FakeVideo> screens = <_FakeVideo>[];

  @override
  Future<CallLocalVideo> openCamera() async {
    final error = cameraError;
    if (error != null) {
      throw CallMediaException(error);
    }
    final opened = _FakeVideo();
    cameras.add(opened);
    return opened;
  }

  @override
  Future<bool> requestScreenConsent() async => true;

  @override
  Future<List<CallScreenSource>> screenSources() async => const [];

  CallScreenSource? selectedScreenSource;
  Completer<void>? screenStartup;

  @override
  Future<CallLocalVideo> openScreen({CallScreenSource? source}) async {
    selectedScreenSource = source;
    await screenStartup?.future;
    final error = screenError;
    if (error != null) {
      throw CallMediaException(error);
    }
    final opened = _FakeVideo();
    screens.add(opened);
    return opened;
  }

  @override
  Future<CallPeerConnection> createPeerConnection({
    required List<CallIceServer> iceServers,
    required CallLocalAudio? audio,
    CallLocalVideo? video,
    bool sendOnly = false,
    required void Function(CallIceCandidate candidate) onIceCandidate,
    required void Function(CallMediaConnectionState state) onConnectionState,
    required void Function(CallRemoteVideo? video) onRemoteVideo,
    void Function(String type, Object? payload)? onStatusMessage,
  }) async {
    if (connectionError case final error?) {
      throw CallMediaException(error);
    }
    final connection = _FakeConnection(
      audio: audio,
      video: video,
      sendOnly: sendOnly,
      iceServers: iceServers,
      onIceCandidate: onIceCandidate,
      onConnectionState: onConnectionState,
      onRemoteVideo: onRemoteVideo,
      onStatusMessage: onStatusMessage,
      index: connections.length + 1,
    );
    connections.add(connection);
    return connection;
  }
}

final class _FakeVideo implements CallLocalVideo {
  bool disposed = false;

  @override
  Widget buildPreview(BuildContext context, {bool contain = false}) =>
      const SizedBox.shrink();

  @override
  Future<void> dispose() async => disposed = true;
}

final class _FakeRemoteVideo implements CallRemoteVideo {
  bool disposed = false;

  @override
  String? get videoTrackId => null;

  @override
  Widget build(BuildContext context, {bool contain = false}) =>
      const SizedBox.shrink();

  @override
  Future<void> dispose() async => disposed = true;
}

final class _FakeAudio implements CallLocalAudio {
  bool disposed = false;
  bool muted = false;
  bool speakerphone = false;
  final List<bool> muteCalls = <bool>[];

  @override
  Future<void> setMuted(bool value) async {
    muted = value;
    muteCalls.add(value);
  }

  final List<bool> speakerphoneCalls = <bool>[];

  @override
  Future<void> setSpeakerphone(bool on) async {
    speakerphone = on;
    speakerphoneCalls.add(on);
  }

  List<CallAudioRoute> availableRoutes = const <CallAudioRoute>[];
  final List<CallAudioRoute> selectedRoutes = <CallAudioRoute>[];
  final routeChangeController = StreamController<void>.broadcast();

  @override
  Future<List<CallAudioRoute>> routes() async => availableRoutes;

  @override
  Future<void> selectRoute(CallAudioRoute route) async =>
      selectedRoutes.add(route);

  @override
  Stream<void> get routeChanges => routeChangeController.stream;

  @override
  Future<void> dispose() async => disposed = true;
}

final class _FakeConnection implements CallPeerConnection {
  _FakeConnection({
    required this.audio,
    required this.video,
    this.sendOnly = false,
    required this.iceServers,
    required this.onIceCandidate,
    required this.onConnectionState,
    required this.onRemoteVideo,
    this.onStatusMessage,
    required this.index,
  });

  final CallLocalAudio? audio;
  final CallLocalVideo? video;
  final bool sendOnly;
  final List<CallIceServer> iceServers;
  final void Function(CallIceCandidate candidate) onIceCandidate;
  final void Function(CallMediaConnectionState state) onConnectionState;
  final void Function(CallRemoteVideo? video) onRemoteVideo;
  final void Function(String type, Object? payload)? onStatusMessage;
  final int index;

  /// Every `sendStatus` call this connection accepted, in order. Stays empty
  /// when [onStatusMessage] was never given — a screen-share connection,
  /// which opens no channel and therefore never sends on one.
  final sentStatus = <({String type, Object? payload})>[];

  @override
  bool sendStatus(String type, {Object? payload}) {
    if (onStatusMessage == null) {
      return false;
    }
    sentStatus.add((type: type, payload: payload));
    return true;
  }

  /// Test hook: the peer's own frame arriving on the status channel.
  void receiveStatus(String type, {Object? payload}) =>
      onStatusMessage?.call(type, payload);

  int createdOffers = 0;
  int createdAnswers = 0;
  bool closed = false;
  final List<CallLocalVideo?> localVideos = <CallLocalVideo?>[];

  @override
  Future<void> setLocalVideo(CallLocalVideo? video) async =>
      localVideos.add(video);
  final List<CallSessionDescription> localDescriptions = [];
  final List<CallSessionDescription> remoteDescriptions = [];
  final List<CallIceCandidate> remoteCandidates = [];

  void emitIceCandidate(CallIceCandidate candidate) =>
      onIceCandidate(candidate);

  void emitConnectionState(CallMediaConnectionState state) =>
      onConnectionState(state);

  int iceRestarts = 0;

  @override
  Future<CallSessionDescription> createOffer({bool iceRestart = false}) async {
    createdOffers++;
    if (iceRestart) {
      iceRestarts++;
    }
    return (type: 'offer', sdp: 'sdp-offer-$index');
  }

  @override
  Future<CallSessionDescription> createAnswer() async {
    createdAnswers++;
    return (type: 'answer', sdp: 'sdp-answer-$index');
  }

  @override
  Future<void> setLocalDescription(CallSessionDescription description) async {
    localDescriptions.add(description);
  }

  @override
  Future<void> setRemoteDescription(CallSessionDescription description) async {
    remoteDescriptions.add(description);
  }

  @override
  Future<void> addIceCandidate(CallIceCandidate candidate) async {
    remoteCandidates.add(candidate);
  }

  @override
  Future<void> close() async => closed = true;
}
