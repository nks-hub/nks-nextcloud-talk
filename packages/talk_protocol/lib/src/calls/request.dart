import 'dart:collection';

import '../conversations/identifiers.dart';
import '../protocol_exception.dart';
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
