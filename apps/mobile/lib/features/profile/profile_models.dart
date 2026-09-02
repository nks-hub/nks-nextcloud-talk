import 'package:talk_protocol/talk_protocol.dart';

import '../../network/nextcloud_api.dart';

final class ProfileStatusCapability {
  const ProfileStatusCapability._({
    required this.enabled,
    required this.supportsBusy,
  });

  const ProfileStatusCapability.unavailable()
    : this._(enabled: false, supportsBusy: false);

  factory ProfileStatusCapability.fromSnapshot(CapabilitySnapshot snapshot) {
    final raw = snapshot.capabilities['user_status'];
    if (raw is! Map<String, Object?> ||
        raw['enabled'] is! bool ||
        raw['supports_emoji'] is! bool) {
      return const ProfileStatusCapability.unavailable();
    }
    final enabled = raw['enabled'] == true && raw['supports_emoji'] == true;
    return ProfileStatusCapability._(
      enabled: enabled,
      supportsBusy: enabled && raw['supports_busy'] == true,
    );
  }

  final bool enabled;
  final bool supportsBusy;

  bool permits(OwnUserStatusType status) {
    return enabled &&
        status != OwnUserStatusType.offline &&
        (status != OwnUserStatusType.busy || supportsBusy);
  }
}

final class OwnProfileSnapshot {
  const OwnProfileSnapshot({
    required this.accountId,
    required this.serverUrl,
    required this.loginName,
    required this.profile,
    required this.statusCapability,
    required this.status,
  });

  final String accountId;
  final String serverUrl;
  final String loginName;
  final OwnProfileResponse profile;
  final ProfileStatusCapability statusCapability;
  final OwnUserStatusResponse? status;

  OwnProfileSnapshot withStatus(OwnUserStatusResponse nextStatus) {
    return OwnProfileSnapshot(
      accountId: accountId,
      serverUrl: serverUrl,
      loginName: loginName,
      profile: profile,
      statusCapability: statusCapability,
      status: nextStatus,
    );
  }
}

enum OwnProfileError {
  accountMissing,
  credentialMissing,
  unsupported,
  invalidInput,
  reauthenticationRequired,
  forbidden,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
}

final class OwnProfileException implements Exception {
  const OwnProfileException(this.code);

  final OwnProfileError code;

  @override
  String toString() => 'OwnProfileException(${code.name})';
}

/// How long a custom status stays before the server clears it.
///
/// Nextcloud stores the expiry as an absolute unix timestamp, but offering an
/// absolute time to pick would be a date picker for something everyone thinks
/// of as "in half an hour". The choices mirror the ones the Nextcloud web UI
/// offers, so a status set here reads the same in the browser.
enum StatusExpiry {
  never,
  halfHour,
  hour,
  fourHours,
  today,
  week;

  /// The absolute unix timestamp to send, resolved against [now].
  ///
  /// `today` means the end of the current day and `week` the end of the
  /// current one, both in the device's own timezone: the server only ever
  /// sees the resolved instant, so a traveller's status expires when their
  /// day ends, not when the server's does.
  int? clearAt(DateTime now) => switch (this) {
    StatusExpiry.never => null,
    StatusExpiry.halfHour => _seconds(now.add(const Duration(minutes: 30))),
    StatusExpiry.hour => _seconds(now.add(const Duration(hours: 1))),
    StatusExpiry.fourHours => _seconds(now.add(const Duration(hours: 4))),
    StatusExpiry.today => _seconds(DateTime(now.year, now.month, now.day + 1)),
    StatusExpiry.week => _seconds(
      DateTime(now.year, now.month, now.day + (8 - now.weekday)),
    ),
  };

  static int _seconds(DateTime value) =>
      value.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
}
