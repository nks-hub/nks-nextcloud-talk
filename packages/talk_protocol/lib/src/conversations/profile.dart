import 'dart:collection';

import '../bootstrap/capabilities.dart';
import '../protocol_exception.dart';
import 'request.dart';
import 'response.dart';

enum ConversationProfileStatus {
  unsupported,
  candidate,
  cursorV4,
  unsupportedWireProfile,
  deferred,
  reauthenticationRequired,
}

enum ConversationProfileDeferralReason {
  fullProbeRequired,
  upgradeRequired,
  rateLimited,
  serviceUnavailable,
  ocsFailure,
  unexpectedHttpStatus,
}

/// A full-request probe used to confirm the cursor-v4 response contract.
final class ConversationProfileProbe {
  ConversationProfileProbe({
    required this.request,
    required this.statusCode,
    required Object? json,
    required Map<String, String> headers,
  }) : _payload = _ConversationProbePayload(
         json,
         UnmodifiableMapView(Map<String, String>.of(headers)),
       );

  final ConversationListRequest request;
  final int statusCode;
  final _ConversationProbePayload _payload;

  @override
  String toString() =>
      'ConversationProfileProbe(mode: ${request.mode.name}, '
      'statusCode: $statusCode)';
}

/// Negotiated endpoint state. A candidate is not active until a valid probe.
final class ConversationProfile {
  const ConversationProfile._({
    required this.status,
    required this.candidatePath,
    required this.activePath,
    this.deferralReason,
  });

  final ConversationProfileStatus status;
  final String? candidatePath;
  final String? activePath;
  final ConversationProfileDeferralReason? deferralReason;

  bool get isActive => status == ConversationProfileStatus.cursorV4;

  bool get requiresReauthentication =>
      status == ConversationProfileStatus.reauthenticationRequired;

  @override
  String toString() => 'ConversationProfile(status: ${status.name})';
}

ConversationProfile resolveConversationProfile({
  required CapabilitySnapshot capabilities,
  ConversationProfileProbe? probe,
}) {
  if (capabilities.context != CapabilityContext.authenticated ||
      !capabilities.supportsTalk('conversation-v4')) {
    return const ConversationProfile._(
      status: ConversationProfileStatus.unsupported,
      candidatePath: null,
      activePath: null,
    );
  }

  if (probe == null) {
    return const ConversationProfile._(
      status: ConversationProfileStatus.candidate,
      candidatePath: conversationV4Path,
      activePath: null,
    );
  }

  try {
    final response = decodeConversationListResponse(
      request: probe.request,
      statusCode: probe.statusCode,
      json: probe._payload.json,
      headers: probe._payload.headers,
    );
    if (response is ConversationListSuccess) {
      if (probe.request.mode != ConversationFetchMode.full) {
        return const ConversationProfile._(
          status: ConversationProfileStatus.deferred,
          candidatePath: conversationV4Path,
          activePath: null,
          deferralReason: ConversationProfileDeferralReason.fullProbeRequired,
        );
      }
      if (response.cursor != null && response.configurationHash != null) {
        return const ConversationProfile._(
          status: ConversationProfileStatus.cursorV4,
          candidatePath: conversationV4Path,
          activePath: conversationV4Path,
        );
      }
      // A legacy conversation-v4 server. Full snapshots stay usable, but no
      // cursor profile is activated and no incremental fetch may be sent.
      return const ConversationProfile._(
        status: ConversationProfileStatus.unsupportedWireProfile,
        candidatePath: conversationV4Path,
        activePath: null,
      );
    }
    if (response is ConversationReauthenticationRequired) {
      return const ConversationProfile._(
        status: ConversationProfileStatus.reauthenticationRequired,
        candidatePath: conversationV4Path,
        activePath: null,
      );
    }
    if (response is ConversationOcsFailure) {
      return const ConversationProfile._(
        status: ConversationProfileStatus.deferred,
        candidatePath: conversationV4Path,
        activePath: null,
        deferralReason: ConversationProfileDeferralReason.ocsFailure,
      );
    }
    if (response is ConversationHttpFailure) {
      return ConversationProfile._(
        status: ConversationProfileStatus.deferred,
        candidatePath: conversationV4Path,
        activePath: null,
        deferralReason: switch (response.kind) {
          ConversationHttpFailureKind.upgradeRequired =>
            ConversationProfileDeferralReason.upgradeRequired,
          ConversationHttpFailureKind.rateLimited =>
            ConversationProfileDeferralReason.rateLimited,
          ConversationHttpFailureKind.serviceUnavailable =>
            ConversationProfileDeferralReason.serviceUnavailable,
        },
      );
    }
  } on TalkProtocolException {
    if (probe.statusCode == 401) {
      return const ConversationProfile._(
        status: ConversationProfileStatus.reauthenticationRequired,
        candidatePath: conversationV4Path,
        activePath: null,
      );
    }
    if (probe.statusCode != 200) {
      return const ConversationProfile._(
        status: ConversationProfileStatus.deferred,
        candidatePath: conversationV4Path,
        activePath: null,
        deferralReason: ConversationProfileDeferralReason.unexpectedHttpStatus,
      );
    }
  }

  return const ConversationProfile._(
    status: ConversationProfileStatus.unsupportedWireProfile,
    candidatePath: conversationV4Path,
    activePath: null,
  );
}

final class _ConversationProbePayload {
  const _ConversationProbePayload(this.json, this.headers);

  final Object? json;
  final Map<String, String> headers;
}
