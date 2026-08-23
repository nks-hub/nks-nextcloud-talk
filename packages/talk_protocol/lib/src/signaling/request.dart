import 'dart:collection';
import 'dart:convert';

import '../conversations/identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';

const String signalingContractUserAgent =
    'com.nkshub.nextcloudtalk signaling-contract/0.1';
const String signalingV3Path = '/ocs/v2.php/apps/spreed/api/v3/signaling';

enum SignalingHttpMethod { get, post }

enum SignalingRequestKind { settings, internalPull, internalBatch }

final class SignalingRequestContext {
  SignalingRequestContext({
    required this.accountId,
    required this.requestId,
    required this.server,
    required this.roomToken,
    required this.credentialGeneration,
    required this.capabilityGeneration,
    required this.settingsRevision,
    required this.connectionEpoch,
    required this.roomEpoch,
  }) {
    if (credentialGeneration < 1 ||
        capabilityGeneration < 1 ||
        settingsRevision.isEmpty ||
        settingsRevision.length > 128 ||
        settingsRevision.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e) ||
        connectionEpoch < 0 ||
        roomEpoch < 0) {
      _requestFailure(r'$.context');
    }
  }

  final AccountId accountId;
  final SignalingRequestId requestId;
  final ServerBase server;
  final ConversationToken roomToken;
  final int credentialGeneration;
  final int capabilityGeneration;
  final String settingsRevision;
  final int connectionEpoch;
  final int roomEpoch;

  @override
  String toString() =>
      'SignalingRequestContext(credentialGeneration: $credentialGeneration, '
      'capabilityGeneration: $capabilityGeneration, '
      'connectionEpoch: $connectionEpoch, roomEpoch: $roomEpoch, '
      'sensitive: <redacted>)';
}

sealed class SignalingHttpRequest {
  SignalingHttpRequest({required this.context, required this.userAgent}) {
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      _requestFailure(r'$.headers.userAgent');
    }
  }

  final SignalingRequestContext context;
  final String userAgent;

  AccountId get accountId => context.accountId;

  SignalingRequestId get requestId => context.requestId;

  ServerBase get server => context.server;

  ConversationToken get roomToken => context.roomToken;

  SignalingHttpMethod get method;

  SignalingRequestKind get kind;

  Uri get uri;

  Map<String, String> get headers;

  Map<String, String>? get formFields;
}

final class SignalingSettingsRequest extends SignalingHttpRequest {
  SignalingSettingsRequest({
    required super.context,
    super.userAgent = signalingContractUserAgent,
  });

  @override
  Map<String, String>? get formFields => null;

  @override
  Map<String, String> get headers => _ocsHeaders(userAgent);

  @override
  SignalingRequestKind get kind => SignalingRequestKind.settings;

  @override
  SignalingHttpMethod get method => SignalingHttpMethod.get;

  @override
  Uri get uri => server.uri.replace(
    path: '${server.basePath}$signalingV3Path/settings',
    queryParameters: <String, String>{
      'token': roomToken.value,
      'format': 'json',
    },
  );

  @override
  String toString() => 'SignalingSettingsRequest(<redacted>)';
}

final class InternalSignalingPullRequest extends SignalingHttpRequest {
  InternalSignalingPullRequest({
    required super.context,
    required this.nextcloudSessionId,
    super.userAgent = signalingContractUserAgent,
  }) {
    if (context.connectionEpoch < 1 || context.roomEpoch < 1) {
      _requestFailure(r'$.context.epoch');
    }
  }

  final ConversationSessionId nextcloudSessionId;

  @override
  Map<String, String>? get formFields => null;

  @override
  Map<String, String> get headers => _ocsHeaders(userAgent);

  @override
  SignalingRequestKind get kind => SignalingRequestKind.internalPull;

  @override
  SignalingHttpMethod get method => SignalingHttpMethod.get;

  @override
  Uri get uri => _internalUri(context);

  @override
  String toString() => 'InternalSignalingPullRequest(<redacted>)';
}

final class InternalSignalingBatchRequest extends SignalingHttpRequest {
  InternalSignalingBatchRequest({
    required super.context,
    required this.nextcloudSessionId,
    required Iterable<SignalingPeerMessage> messages,
    super.userAgent = signalingContractUserAgent,
  }) : messages = List<SignalingPeerMessage>.unmodifiable(messages) {
    if (context.connectionEpoch < 1 ||
        context.roomEpoch < 1 ||
        this.messages.isEmpty ||
        this.messages.length > 64 ||
        this.messages.any((message) => message.recipient == null)) {
      _requestFailure(r'$.messages');
    }
    formFields = UnmodifiableMapView(<String, String>{
      'messages': jsonEncode(
        this.messages
            .map(
              (message) => <String, Object?>{
                'ev': 'message',
                'fn': jsonEncode(message.toWire()),
                'sessionId': nextcloudSessionId.value,
              },
            )
            .toList(growable: false),
      ),
    });
  }

  final ConversationSessionId nextcloudSessionId;
  final List<SignalingPeerMessage> messages;

  @override
  late final Map<String, String> formFields;

  @override
  Map<String, String> get headers => UnmodifiableMapView(<String, String>{
    ..._ocsHeaders(userAgent),
    'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
  });

  @override
  SignalingRequestKind get kind => SignalingRequestKind.internalBatch;

  @override
  SignalingHttpMethod get method => SignalingHttpMethod.post;

  @override
  Uri get uri => _internalUri(context);

  @override
  String toString() =>
      'InternalSignalingBatchRequest(messages: ${messages.length}, '
      'sensitive: <redacted>)';
}

Map<String, String> _ocsHeaders(String userAgent) => UnmodifiableMapView({
  'Accept': 'application/json',
  'OCS-APIRequest': 'true',
  'User-Agent': userAgent,
});

Uri _internalUri(SignalingRequestContext context) => context.server.uri.replace(
  path:
      '${context.server.basePath}$signalingV3Path/'
      '${context.roomToken.value}',
  queryParameters: const <String, String>{'format': 'json'},
);

Never _requestFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSignalingRequest, path);
