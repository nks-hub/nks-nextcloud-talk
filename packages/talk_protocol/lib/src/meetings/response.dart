import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../protocol_exception.dart';

const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidRoomSettingsResponse;

const String _davNamespace = 'DAV:';
const String _caldavNamespace = 'urn:ietf:params:xml:ns:caldav';

/// A listing bigger than this is a server that is not answering the question
/// asked; nobody has this many calendars.
const int maximumCalendarListingBytes = 512 * 1024;
const int maximumCalendars = 64;

/// The collections every Nextcloud account has that are not calendars a person
/// writes a meeting into. They come back from the same `PROPFIND` and are
/// dropped by name, because their `resourcetype` does not tell them apart from
/// a real calendar on this server.
const Set<String> _schedulingCollections = {'inbox', 'outbox', 'trashbin'};

/// One calendar the account may try to schedule into.
final class CalendarEntry {
  const CalendarEntry({required this.uri, required this.displayName});

  /// The last path segment, which is what the meeting endpoint accepts.
  final String uri;
  final String displayName;

  @override
  String toString() => 'CalendarEntry(uri: $uri)';
}

enum CalendarListOutcome {
  listed,
  reauthenticationRequired,
  unavailable,
  transientError,
}

final class CalendarListResponse {
  const CalendarListResponse._({
    required this.outcome,
    required this.calendars,
  });

  final CalendarListOutcome outcome;
  final List<CalendarEntry> calendars;

  @override
  String toString() =>
      'CalendarListResponse(outcome: ${outcome.name}, '
      'calendars: ${calendars.length})';
}

CalendarListResponse decodeCalendarListResponse({
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 207:
      break;
    case 401:
      return const CalendarListResponse._(
        outcome: CalendarListOutcome.reauthenticationRequired,
        calendars: <CalendarEntry>[],
      );
    case 403:
    case 404:
      return const CalendarListResponse._(
        outcome: CalendarListOutcome.unavailable,
        calendars: <CalendarEntry>[],
      );
    case 429:
    case 503:
      return const CalendarListResponse._(
        outcome: CalendarListOutcome.transientError,
        calendars: <CalendarEntry>[],
      );
    default:
      protocolFailure(_responseCode, r'$.statusCode');
  }
  if (body.length > maximumCalendarListingBytes) {
    protocolFailure(_responseCode, r'$.body');
  }
  final XmlDocument document;
  try {
    document = XmlDocument.parse(utf8.decode(body));
  } on Object {
    return protocolFailure(_responseCode, r'$.body');
  }
  final calendars = <CalendarEntry>[];
  for (final response in document.findAllElements(
    'response',
    namespaceUri: _davNamespace,
  )) {
    if (calendars.length >= maximumCalendars) {
      break;
    }
    final entry = _calendarOf(response);
    if (entry != null) {
      calendars.add(entry);
    }
  }
  return CalendarListResponse._(
    outcome: CalendarListOutcome.listed,
    calendars: UnmodifiableListView(calendars),
  );
}

CalendarEntry? _calendarOf(XmlElement response) {
  final href = response
      .getElement('href', namespaceUri: _davNamespace)
      ?.innerText
      .trim();
  if (href == null || href.isEmpty) {
    return null;
  }
  final segments = Uri.parse(href).pathSegments.where((s) => s.isNotEmpty);
  if (segments.isEmpty) {
    return null;
  }
  final uri = segments.last;
  if (_schedulingCollections.contains(uri)) {
    return null;
  }
  // Only the `200` block describes what exists; the server puts properties it
  // does not serve into a `404` block of its own.
  final available = response
      .findElements('propstat', namespaceUri: _davNamespace)
      .where(
        (propstat) =>
            propstat
                .getElement('status', namespaceUri: _davNamespace)
                ?.innerText
                .contains(' 200 ') ??
            false,
      )
      .expand(
        (propstat) =>
            propstat.findElements('prop', namespaceUri: _davNamespace),
      );
  String? displayName;
  var takesEvents = false;
  for (final prop in available) {
    displayName ??= prop
        .getElement('displayname', namespaceUri: _davNamespace)
        ?.innerText
        .trim();
    final components = prop.getElement(
      'supported-calendar-component-set',
      namespaceUri: _caldavNamespace,
    );
    if (components != null) {
      takesEvents = components
          .findElements('comp', namespaceUri: _caldavNamespace)
          .any((comp) => comp.getAttribute('name') == 'VEVENT');
    }
  }
  if (!takesEvents || displayName == null || displayName.isEmpty) {
    return null;
  }
  return CalendarEntry(uri: uri, displayName: displayName);
}

/// Why the server refused to write the meeting.
///
/// The names are the server's own `ocs.data.error` vocabulary, measured on
/// 9 September 2026.
enum ScheduleMeetingRefusal {
  /// The calendar does not exist or is not one this account may write to.
  calendar,

  /// The organising account has no e-mail address, so nobody can be invited.
  email,
  start,
  end,

  /// A `400` with an error this client does not know.
  unknown,
}

enum ScheduleMeetingOutcome {
  scheduled,
  refused,
  reauthenticationRequired,
  forbidden,
  roomMissing,
  rateLimited,

  /// Including the `500` the reference server answers for a calendar that
  /// cannot take the event. Nothing was necessarily written, and nothing may
  /// be retried automatically: the endpoint does not deduplicate.
  serverFailure,
}

final class ScheduleMeetingResponse {
  const ScheduleMeetingResponse._({
    required this.outcome,
    required this.refusal,
  });

  final ScheduleMeetingOutcome outcome;
  final ScheduleMeetingRefusal? refusal;

  bool get isSuccess => outcome == ScheduleMeetingOutcome.scheduled;

  @override
  String toString() =>
      'ScheduleMeetingResponse(outcome: ${outcome.name}, '
      'refusal: ${refusal?.name})';
}

ScheduleMeetingResponse decodeScheduleMeetingResponse({
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      return const ScheduleMeetingResponse._(
        outcome: ScheduleMeetingOutcome.scheduled,
        refusal: null,
      );
    case 400:
      return ScheduleMeetingResponse._(
        outcome: ScheduleMeetingOutcome.refused,
        refusal: _refusalOf(body),
      );
    case 401:
      return const ScheduleMeetingResponse._(
        outcome: ScheduleMeetingOutcome.reauthenticationRequired,
        refusal: null,
      );
    case 403:
      return const ScheduleMeetingResponse._(
        outcome: ScheduleMeetingOutcome.forbidden,
        refusal: null,
      );
    case 404:
      return const ScheduleMeetingResponse._(
        outcome: ScheduleMeetingOutcome.roomMissing,
        refusal: null,
      );
    case 429:
      return const ScheduleMeetingResponse._(
        outcome: ScheduleMeetingOutcome.rateLimited,
        refusal: null,
      );
    default:
      if (statusCode >= 500 && statusCode <= 599) {
        return const ScheduleMeetingResponse._(
          outcome: ScheduleMeetingOutcome.serverFailure,
          refusal: null,
        );
      }
      return protocolFailure(_responseCode, r'$.statusCode');
  }
}

ScheduleMeetingRefusal _refusalOf(Uint8List body) {
  if (body.isEmpty || body.length > 64 * 1024) {
    return ScheduleMeetingRefusal.unknown;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
  } on Object {
    return ScheduleMeetingRefusal.unknown;
  }
  if (decoded is! Map<String, Object?>) {
    return ScheduleMeetingRefusal.unknown;
  }
  final ocs = decoded['ocs'];
  final data = ocs is Map<String, Object?> ? ocs['data'] : null;
  final error = data is Map<String, Object?> ? data['error'] : null;
  return switch (error) {
    'calendar' => ScheduleMeetingRefusal.calendar,
    'email' => ScheduleMeetingRefusal.email,
    'start' => ScheduleMeetingRefusal.start,
    'end' => ScheduleMeetingRefusal.end,
    _ => ScheduleMeetingRefusal.unknown,
  };
}
