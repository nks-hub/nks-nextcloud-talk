import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../bootstrap/capabilities.dart';
import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'response.dart';

const String botAdminContractUserAgent =
    'com.nkshub.nextcloudtalk bot-admin-contract/0.1';

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidRoomSettingsRequest;
const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidRoomSettingsResponse;

/// A server with more bots than this is not something a phone screen answers;
/// the list is cut and says so.
const int maximumAdminBots = 200;
const int maximumBotAdminBytes = 512 * 1024;

/// Reads every bot installed on the server.
///
/// `GET /ocs/v2.php/apps/spreed/api/v1/bot/admin`, behind `bots-v1`. This is
/// the SERVER-WIDE list an administrator sees, not the per-room bot management
/// a moderator has. Measured against a Talk 22 instance on 9 September 2026:
/// `200` with the list for an administrator, and `403` with
/// `"Logged in account must be an admin"` for an ordinary account.
final class BotAdminListRequest {
  BotAdminListRequest({
    required this.accountId,
    required this.server,
    required CapabilitySnapshot capabilities,
    this.userAgent = botAdminContractUserAgent,
  }) {
    if (capabilities.context != CapabilityContext.authenticated ||
        !capabilities.supportsTalk('bots-v1')) {
      protocolFailure(_requestCode, r'$.capabilities.bots-v1');
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(_requestCode, r'$.headers.userAgent');
    }
  }

  final AccountId accountId;
  final ServerBase server;
  final String userAgent;

  String get httpMethod => 'GET';

  Uri get uri => server.uri.replace(
    path: '${server.basePath}/ocs/v2.php/apps/spreed/api/v1/bot/admin',
    queryParameters: const {'format': 'json'},
  );

  Map<String, String> get headers => UnmodifiableMapView({
    'Accept': 'application/json',
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
  });

  @override
  String toString() => 'BotAdminListRequest(sensitive: <redacted>)';
}

/// One installed bot, reduced to what an administrator may be shown.
///
/// The server also returns the bot's `url` and its hash. Neither is here: a
/// webhook address is operator infrastructure and can carry a token in its
/// path or query, and this screen exists to be read out loud over a support
/// call. [urlHost] is the host alone, which is enough to tell two bots apart
/// without carrying the secret part of the address.
final class AdminBot {
  const AdminBot._({
    required this.id,
    required this.name,
    required this.description,
    required this.urlHost,
    required this.state,
    required this.errorCount,
    required this.lastErrorAt,
    required this.lastErrorMessage,
  });

  final int id;
  final String name;
  final String? description;

  /// The host of the webhook address, or null when it cannot be read as one.
  final String? urlHost;

  final BotState state;
  final int errorCount;
  final DateTime? lastErrorAt;

  /// The server's own last error text, bounded. Never a credential: what the
  /// server stores here is the transport failure, and anything longer than
  /// [maximumBotErrorCharacters] is cut rather than shown in full.
  final String? lastErrorMessage;

  /// Whether the server has counted transport failures against this bot.
  ///
  /// Deliberately false for [BotState.unavailable]. For a bot whose providing
  /// app is switched off, `adminListBots` ASSIGNS `error_count = 1`,
  /// `last_error_date = now` and `last_error_message = "App disabled"` over
  /// whatever was stored, so none of the three describes the bot's own health:
  /// the count is invented, the moment is the moment of this request, and the
  /// real count is hidden. A switched-off app is the administrator's own doing,
  /// not a bot that is breaking.
  bool get isFailing => errorCount > 0 && state != BotState.unavailable;

  @override
  String toString() =>
      'AdminBot(id: $id, state: ${state.name}, '
      'errors: $errorCount)';
}

const int maximumBotErrorCharacters = 200;

enum BotAdminOutcome {
  listed,
  reauthenticationRequired,

  /// The account is not an administrator of this server.
  forbidden,
  unsupported,
  rateLimited,
  serverFailure,
}

final class BotAdminListResponse {
  const BotAdminListResponse._({
    required this.outcome,
    required this.bots,
    required this.truncated,
  });

  final BotAdminOutcome outcome;
  final List<AdminBot> bots;

  /// The server returned more than [maximumAdminBots] and the rest was
  /// dropped.
  final bool truncated;

  @override
  String toString() =>
      'BotAdminListResponse(outcome: ${outcome.name}, bots: ${bots.length})';
}

BotAdminListResponse decodeBotAdminListResponse({
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      break;
    case 401:
      return const BotAdminListResponse._(
        outcome: BotAdminOutcome.reauthenticationRequired,
        bots: <AdminBot>[],
        truncated: false,
      );
    case 403:
      return const BotAdminListResponse._(
        outcome: BotAdminOutcome.forbidden,
        bots: <AdminBot>[],
        truncated: false,
      );
    case 404:
      return const BotAdminListResponse._(
        outcome: BotAdminOutcome.unsupported,
        bots: <AdminBot>[],
        truncated: false,
      );
    case 429:
      return const BotAdminListResponse._(
        outcome: BotAdminOutcome.rateLimited,
        bots: <AdminBot>[],
        truncated: false,
      );
    default:
      if (statusCode >= 500 && statusCode <= 599) {
        return const BotAdminListResponse._(
          outcome: BotAdminOutcome.serverFailure,
          bots: <AdminBot>[],
          truncated: false,
        );
      }
      return protocolFailure(_responseCode, r'$.statusCode');
  }
  if (body.length > maximumBotAdminBytes) {
    protocolFailure(_responseCode, r'$.body');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
  } on Object {
    return protocolFailure(_responseCode, r'$.body');
  }
  final root = requireObject(decoded, path: r'$', code: _responseCode);
  final ocs = requireObject(root['ocs'], path: r'$.ocs', code: _responseCode);
  final rows = requireList(
    ocs['data'],
    path: r'$.ocs.data',
    code: _responseCode,
  );
  final bots = <AdminBot>[];
  for (
    var index = 0;
    index < rows.length && index < maximumAdminBots;
    index++
  ) {
    bots.add(_botOf(rows[index], index));
  }
  return BotAdminListResponse._(
    outcome: BotAdminOutcome.listed,
    bots: UnmodifiableListView(bots),
    truncated: rows.length > maximumAdminBots,
  );
}

AdminBot _botOf(Object? row, int index) {
  final path =
      r'$.ocs.data['
      '$index]';
  final bot = requireObject(row, path: path, code: _responseCode);
  final rawUrl = bot['url'];
  return AdminBot._(
    id: requireInt(bot['id'], path: '$path.id', code: _responseCode),
    name: requireString(
      bot['name'],
      path: '$path.name',
      code: _responseCode,
      maxLength: 64,
    ),
    description: _optionalText(bot['description'], 4096),
    urlHost: rawUrl is String ? Uri.tryParse(rawUrl)?.host : null,
    state: switch (requireInt(
      bot['state'],
      path: '$path.state',
      code: _responseCode,
    )) {
      0 => BotState.disabled,
      1 => BotState.enabled,
      2 => BotState.noSetup,
      // Talk substitutes this state, an error count of one and "App disabled"
      // for a bot whose providing app is not enabled. Measured on Talk 22.0.17
      // on 9 September 2026; a decoder stopping at `2` rejects the whole list
      // as soon as one such bot is installed.
      3 => BotState.unavailable,
      _ => protocolFailure(_responseCode, '$path.state'),
    },
    errorCount: requireInt(
      bot['error_count'],
      path: '$path.error_count',
      code: _responseCode,
    ),
    lastErrorAt: switch (bot['last_error_date']) {
      final int seconds when seconds > 0 => DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000,
        isUtc: true,
      ),
      _ => null,
    },
    lastErrorMessage: _optionalText(
      bot['last_error_message'],
      maximumBotErrorCharacters,
    ),
  );
}

String? _optionalText(Object? value, int limit) {
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  return trimmed.length <= limit ? trimmed : '${trimmed.substring(0, limit)}…';
}
