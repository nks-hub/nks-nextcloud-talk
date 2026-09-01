import '../bootstrap/capabilities.dart';

final class ReferenceCapabilityProfile {
  const ReferenceCapabilityProfile._({required this.enabled});

  factory ReferenceCapabilityProfile.fromCapabilities(
    CapabilitySnapshot snapshot,
  ) {
    final core = snapshot.capabilities['core'];
    return ReferenceCapabilityProfile._(
      enabled:
          snapshot.context == CapabilityContext.authenticated &&
          core is Map<String, Object?> &&
          core['reference-api'] == true,
    );
  }

  final bool enabled;
}
