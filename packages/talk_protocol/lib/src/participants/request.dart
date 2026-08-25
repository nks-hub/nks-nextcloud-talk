import 'dart:collection';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const String participantsV4Path = '/ocs/v2.php/apps/spreed/api/v4/room';
const String participantsContractUserAgent =
    'com.nkshub.nextcloudtalk participants-contract/0.1';

/// Request for the participant list of a single room. Read-only: this
/// contract never issues membership or moderation changes.
final class ParticipantsRequest {
  ParticipantsRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    this.includeStatus = true,
    this.userAgent = participantsContractUserAgent,
  }) {
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidParticipantsRequest,
        r'$.headers.userAgent',
      );
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final bool includeStatus;
  final String userAgent;

  Map<String, String> get queryParameters => UnmodifiableMapView({
    'format': 'json',
    'includeStatus': includeStatus.toString(),
  });

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$participantsV4Path/'
        '${roomToken.value}/participants',
    queryParameters: queryParameters,
  );

  @override
  String toString() =>
      'ParticipantsRequest(includeStatus: $includeStatus)';
}
