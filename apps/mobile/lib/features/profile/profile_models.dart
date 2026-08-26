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
