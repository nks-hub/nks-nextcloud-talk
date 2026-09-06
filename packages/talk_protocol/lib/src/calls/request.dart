import 'dart:collection';

import '../conversations/identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'models.dart';

const String callRestContractUserAgent =
    'com.nkshub.nextcloudtalk call-rest-contract/0.1';
const String callRestV4Path = '/ocs/v2.php/apps/spreed/api/v4/call';

enum CallRestMethod { get, post, put, delete }

final class CallRequestContext {
  CallRequestContext({
    required this.authority,
    required this.mutationSequence,
  }) {
    if (mutationSequence < 0) {
      protocolFailure(
        TalkProtocolErrorCode.invalidCallRequest,
        r'$.context.mutationSequence',
      );
    }
  }

  final CallLifecycleAuthority authority;
  final int mutationSequence;
}

sealed class CallRestRequest {
  CallRestRequest({required this.context, required this.userAgent}) {
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidCallRequest,
        r'$.headers.userAgent',
      );
    }
  }

  final CallRequestContext context;
  final String userAgent;

  CallLifecycleAuthority get authority => context.authority;
  AccountId get accountId => authority.accountId;
  ConversationToken get roomToken => authority.roomToken;

  CallRestMethod get method;
  Map<String, List<String>>? get formFields;

  Uri get uri => authority.server.uri.replace(
    path: '${authority.server.basePath}$callRestV4Path/${roomToken.value}',
    queryParameters: queryParameters,
  );

  Map<String, String> get queryParameters => const {'format': 'json'};

  Map<String, String> get headers => UnmodifiableMapView({
    'Accept': 'application/json',
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    if (formFields != null)
      'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
  });
}

final class CallPeersRequest extends CallRestRequest {
  CallPeersRequest({
    required super.context,
    super.userAgent = callRestContractUserAgent,
  });

  @override
  CallRestMethod get method => CallRestMethod.get;

  @override
  Map<String, List<String>>? get formFields => null;

  @override
  String toString() => 'CallPeersRequest(sensitive: <redacted>)';
}

final class JoinCallRequest extends CallRestRequest {
  JoinCallRequest({
    required super.context,
    required this.flags,
    required this.silent,
    required this.recordingConsent,
    Iterable<ConversationSessionId> silentFor = const [],
    super.userAgent = callRestContractUserAgent,
  }) : silentFor = List.unmodifiable(silentFor) {
    _requireMutation(context);
    CallInCallFlags.parse(flags.value, requireJoined: true);
    if (this.silentFor.length > 128 ||
        this.silentFor.map((id) => id.value).toSet().length !=
            this.silentFor.length) {
      protocolFailure(TalkProtocolErrorCode.invalidCallRequest, r'$.silentFor');
    }
  }

  final CallInCallFlags flags;
  final bool silent;
  final bool recordingConsent;
  final List<ConversationSessionId> silentFor;

  @override
  CallRestMethod get method => CallRestMethod.post;

  @override
  late final Map<String, List<String>> formFields = UnmodifiableMapView({
    'flags': <String>[flags.value.toString()],
    'silent': <String>[silent ? '1' : '0'],
    'recordingConsent': <String>[recordingConsent ? '1' : '0'],
    if (silentFor.isNotEmpty)
      'silentFor[]': silentFor.map((id) => id.value).toList(growable: false),
  });

  @override
  String toString() =>
      'JoinCallRequest(flags: ${flags.value}, silent: $silent, '
      'recordingConsent: $recordingConsent, silentFor: ${silentFor.length}, '
      'sensitive: <redacted>)';
}

final class UpdateCallFlagsRequest extends CallRestRequest {
  UpdateCallFlagsRequest({
    required super.context,
    required this.flags,
    super.userAgent = callRestContractUserAgent,
  }) {
    _requireMutation(context);
    CallInCallFlags.parse(flags.value, requireJoined: true);
  }

  final CallInCallFlags flags;

  @override
  CallRestMethod get method => CallRestMethod.put;

  @override
  late final Map<String, List<String>> formFields = UnmodifiableMapView({
    'flags': <String>[flags.value.toString()],
  });

  @override
  String toString() =>
      'UpdateCallFlagsRequest(flags: ${flags.value}, sensitive: <redacted>)';
}

final class LeaveCallRequest extends CallRestRequest {
  LeaveCallRequest({
    required super.context,
    required this.endForEveryone,
    super.userAgent = callRestContractUserAgent,
  }) {
    _requireMutation(context);
  }

  final bool endForEveryone;

  @override
  CallRestMethod get method => CallRestMethod.delete;

  @override
  Map<String, List<String>>? get formFields => null;

  @override
  Map<String, String> get queryParameters => {
    'all': endForEveryone ? '1' : '0',
    'format': 'json',
  };

  @override
  String toString() =>
      'LeaveCallRequest(endForEveryone: $endForEveryone, '
      'sensitive: <redacted>)';
}

void _requireMutation(CallRequestContext context) {
  if (context.mutationSequence < 1) {
    protocolFailure(
      TalkProtocolErrorCode.invalidCallRequest,
      r'$.context.mutationSequence',
    );
  }
}

// ---------------------------------------------------------------------------
// Call recording — Talk `docs/recording.md`, API v1, capability
// `recording-v1`. Verified against the live spreed controller
// (`lib/Controller/RecordingController.php`): `start(int $status)` and
// `stop()` are both routed `#[ApiRoute(url: '/api/{apiVersion}/recording/
// {token}', requirements: ['apiVersion' => '(v1)'])]` and both carry
// `#[RequireLoggedInModeratorParticipant]`, so the server refuses a
// non-moderator on its own. This client mirrors that with a visibility gate
// (moderator and the capability) rather than trusting the server alone,
// the same way the breakout-rooms control is gated in
// `room_details_actions.part.dart` — the check belongs to the UI layer that
// decides whether to offer the control, not to this request.
// ---------------------------------------------------------------------------

const String callRecordingV1Path = '/ocs/v2.php/apps/spreed/api/v1/recording';

/// Call recording status constants from Talk `docs/constants.md`, "Call
/// recording status": `0` no recording, `1`/`2` an ongoing video/audio-only
/// recording, `3`/`4` one that is starting, `5` a recording that failed.
/// `ConversationRoom.callRecording` already carries this exact `0..5` bound.
///
/// Starting a recording only ever asks for one of the two STARTING states —
/// the server owns the transition to "ongoing" once its recording backend
/// confirms, and to "failed" if it does not.
enum CallRecordingStartMode {
  video(3),
  audioOnly(4);

  const CallRecordingStartMode(this.wireValue);

  final int wireValue;
}

Uri _callRecordingUri(ServerBase server, ConversationToken roomToken) {
  return server.uri.replace(
    path: '${server.basePath}$callRecordingV1Path/${roomToken.value}',
    queryParameters: const {'format': 'json'},
  );
}

void _validateCallRecordingUserAgent(String userAgent) {
  if (userAgent.isEmpty ||
      userAgent.length > 256 ||
      userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(
      TalkProtocolErrorCode.invalidCallRequest,
      r'$.headers.userAgent',
    );
  }
}

/// One moderator-only call recording control.
///
/// `POST` and `DELETE /ocs/v2.php/apps/spreed/api/v1/recording/{token}`. Both
/// answer `200` on success, `400` when the recording configuration is
/// disabled, the call is not active, or (`start` only) the requested status
/// is invalid or a recording is already running; `401` when the participant
/// is a guest; `403` when they are not a moderator or owner; and `412` when a
/// lobby is active and they are not a moderator — so both decode through
/// [decodeCallRecordingResponse].
sealed class CallRecordingRequest {
  CallRecordingRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    this.userAgent = callRestContractUserAgent,
  }) {
    _validateCallRecordingUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;

  String get httpMethod;

  /// Form fields for the request body, or `null` when the endpoint takes none.
  Map<String, String>? get formBody;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => _callRecordingUri(server, roomToken);
}

/// `POST /recording/{token}` — asks the server to start recording the call,
/// with or without video.
final class StartCallRecordingRequest extends CallRecordingRequest {
  StartCallRecordingRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.mode,
    super.userAgent,
  });

  final CallRecordingStartMode mode;

  @override
  String get httpMethod => 'POST';

  @override
  Map<String, String>? get formBody =>
      UnmodifiableMapView({'status': mode.wireValue.toString()});

  @override
  String toString() => 'StartCallRecordingRequest(mode: ${mode.name})';
}

/// `DELETE /recording/{token}` — stops a recording that is starting or
/// already in progress.
final class StopCallRecordingRequest extends CallRecordingRequest {
  StopCallRecordingRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    super.userAgent,
  });

  @override
  String get httpMethod => 'DELETE';

  @override
  Map<String, String>? get formBody => null;

  @override
  String toString() => 'StopCallRecordingRequest()';
}
