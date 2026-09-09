import 'dart:collection';

import '../bootstrap/capabilities.dart';
import '../conversations/identifiers.dart';
import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const String meetingContractUserAgent =
    'com.nkshub.nextcloudtalk meeting-contract/0.1';

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidRoomSettingsRequest;

const int meetingMaximumTitleCharacters = 255;
const int meetingMaximumDescriptionCharacters = 4096;

/// The longest meeting this client will schedule in one request.
///
/// Nothing on the server refuses a long one; this is a guard against a date
/// picker returning a year by accident, which would blank out every calendar
/// it is written into.
const Duration meetingMaximumDuration = Duration(days: 1);

/// Lists the account's own calendars.
///
/// `PROPFIND /remote.php/dav/calendars/{loginName}/` with `Depth: 1`. Measured
/// against the reference instance on 9 September 2026: the server answers the
/// collection plus `personal`, `contact_birthdays`, `inbox`, `outbox` and
/// `trashbin`, and it does NOT serve `current-user-privileges` — that property
/// comes back `404` inside its own `propstat`. Whether a calendar will accept
/// an event therefore cannot be read in advance and only the attempt says so.
final class CalendarListRequest {
  CalendarListRequest({
    required this.accountId,
    required this.server,
    required this.loginName,
    this.userAgent = meetingContractUserAgent,
  }) {
    if (loginName.isEmpty ||
        loginName.length > 256 ||
        loginName.contains('/') ||
        _hasControlCharacter(loginName)) {
      protocolFailure(_requestCode, r'$.loginName');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final String loginName;
  final String userAgent;

  String get httpMethod => 'PROPFIND';

  Uri get uri => server.uri.replace(
    pathSegments: <String>[
      ...server.uri.pathSegments.where((segment) => segment.isNotEmpty),
      'remote.php',
      'dav',
      'calendars',
      loginName,
      '',
    ],
    query: null,
  );

  Map<String, String> get headers => UnmodifiableMapView({
    'Depth': '1',
    'User-Agent': userAgent,
    'Content-Type': 'application/xml; charset=utf-8',
  });

  /// Only what the picker shows: the name and whether the calendar takes
  /// events at all.
  String get body =>
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<d:propfind xmlns:d="DAV:" '
      'xmlns:cal="urn:ietf:params:xml:ns:caldav">'
      '<d:prop>'
      '<d:displayname/>'
      '<d:resourcetype/>'
      '<cal:supported-calendar-component-set/>'
      '</d:prop>'
      '</d:propfind>';

  @override
  String toString() => 'CalendarListRequest(sensitive: <redacted>)';
}

/// Writes a calendar event for this conversation and invites its participants.
///
/// `POST /ocs/v2.php/apps/spreed/api/v4/room/{token}/meeting`, behind the
/// server's `schedule-meeting` capability. Measured against the reference
/// instance on 9 September 2026:
///
/// - The server writes the event, sets the conversation's call address as its
///   `LOCATION` and adds the room's participants as attendees on its own.
/// - A start in the past is refused with `400 {"error": "start"}`, an end at
///   or before the start with `400 {"error": "end"}`, an unknown calendar with
///   `400 {"error": "calendar"}`, and an organiser with no e-mail address with
///   `400 {"error": "email"}`.
/// - A calendar that cannot take the event — the generated birthday one —
///   answers `500` with an empty body. That is a server fault, not a rejection
///   this client can pre-empt: privileges are not published (see
///   [CalendarListRequest]).
/// - `title` and `end` are both optional and an empty title is accepted.
/// - THE SERVER DOES NOT DEDUPLICATE. The identical request sent twice writes
///   two events and invites everybody twice, so not repeating it is entirely
///   this side's job.
/// - Any participant may schedule; it is not moderator-only.
///
/// [start] and [end] are validated here rather than left to the server so a
/// mistyped date is refused before anybody is invited.
final class ScheduleMeetingRequest {
  ScheduleMeetingRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.calendarUri,
    required this.start,
    required CapabilitySnapshot capabilities,
    required DateTime now,
    this.end,
    this.title,
    this.description,
    this.attendeeIds = const <int>[],
    this.userAgent = meetingContractUserAgent,
  }) {
    if (capabilities.context != CapabilityContext.authenticated ||
        !capabilities.supportsTalk('schedule-meeting')) {
      protocolFailure(_requestCode, r'$.capabilities.schedule-meeting');
    }
    if (calendarUri.isEmpty ||
        calendarUri.length > 255 ||
        calendarUri.contains('/') ||
        _hasControlCharacter(calendarUri)) {
      protocolFailure(_requestCode, r'$.calendarUri');
    }
    if (!start.isUtc || !start.isAfter(now)) {
      protocolFailure(_requestCode, r'$.start');
    }
    final finish = end;
    if (finish != null &&
        (!finish.isUtc ||
            !finish.isAfter(start) ||
            finish.difference(start) > meetingMaximumDuration)) {
      protocolFailure(_requestCode, r'$.end');
    }
    final name = title;
    if (name != null &&
        (name.length > meetingMaximumTitleCharacters ||
            _hasControlCharacter(name))) {
      protocolFailure(_requestCode, r'$.title');
    }
    final text = description;
    if (text != null && text.length > meetingMaximumDescriptionCharacters) {
      protocolFailure(_requestCode, r'$.description');
    }
    if (attendeeIds.length > 512 || attendeeIds.any((id) => id < 1)) {
      protocolFailure(_requestCode, r'$.attendeeIds');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;

  /// The calendar's own URI segment, for example `personal` — not its full
  /// DAV address, which the server rejects with `400 {"error": "calendar"}`.
  final String calendarUri;

  final DateTime start;
  final DateTime? end;
  final String? title;
  final String? description;
  final List<int> attendeeIds;
  final String userAgent;

  String get httpMethod => 'POST';

  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}/ocs/v2.php/apps/spreed/api/v4/room/'
        '${roomToken.value}/meeting',
    queryParameters: const {'format': 'json'},
  );

  Map<String, String> get headers => UnmodifiableMapView({
    'Accept': 'application/json',
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
  });

  Map<String, List<String>> get formFields => UnmodifiableMapView({
    'calendarUri': <String>[calendarUri],
    'start': <String>['${start.millisecondsSinceEpoch ~/ 1000}'],
    if (end case final finish?)
      'end': <String>['${finish.millisecondsSinceEpoch ~/ 1000}'],
    if (title case final name?) 'title': <String>[name],
    if (description case final text?) 'description': <String>[text],
    if (attendeeIds.isNotEmpty)
      'attendeeIds[]': attendeeIds.map((id) => '$id').toList(growable: false),
  });

  @override
  String toString() => 'ScheduleMeetingRequest(sensitive: <redacted>)';
}

bool _hasControlCharacter(String value) =>
    value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

void _validateUserAgent(String userAgent) {
  if (userAgent.isEmpty ||
      userAgent.length > 256 ||
      userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(_requestCode, r'$.headers.userAgent');
  }
}
