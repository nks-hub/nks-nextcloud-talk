import 'dart:collection';

import '../json_value.dart';
import '../protocol_exception.dart';

/// Whether a capability snapshot was fetched before or after authentication.
enum CapabilityContext { anonymous, authenticated }

/// User privacy policy for exposing chat read status.
enum ChatReadPrivacy { public, private }

/// Version fields from the OCS capability response.
final class NextcloudVersion {
  const NextcloudVersion({
    required this.major,
    required this.minor,
    required this.micro,
    required this.versionString,
    required this.edition,
    required this.extendedSupport,
  });

  factory NextcloudVersion.fromJson(Object? json) {
    const code = TalkProtocolErrorCode.invalidCapabilities;
    final value = requireObject(json, path: r'$.ocs.data.version', code: code);
    final rawExtendedSupport = value['extendedSupport'];
    return NextcloudVersion(
      major: requireInt(
        value['major'],
        path: r'$.ocs.data.version.major',
        code: code,
        minimum: 0,
      ),
      minor: requireInt(
        value['minor'],
        path: r'$.ocs.data.version.minor',
        code: code,
        minimum: 0,
      ),
      micro: requireInt(
        value['micro'],
        path: r'$.ocs.data.version.micro',
        code: code,
        minimum: 0,
      ),
      versionString: requireString(
        value['string'],
        path: r'$.ocs.data.version.string',
        code: code,
        minLength: 1,
        maxLength: 128,
      ),
      edition: requireString(
        value['edition'],
        path: r'$.ocs.data.version.edition',
        code: code,
        maxLength: 128,
      ),
      extendedSupport: rawExtendedSupport == null
          ? null
          : requireBool(
              rawExtendedSupport,
              path: r'$.ocs.data.version.extendedSupport',
              code: code,
            ),
    );
  }

  final int major;
  final int minor;
  final int micro;
  final String versionString;
  final String edition;
  final bool? extendedSupport;
}

/// Validated OCS capabilities with unknown namespaces preserved for resolvers.
final class CapabilitySnapshot {
  CapabilitySnapshot._({
    required this.context,
    required this.version,
    required Map<String, Object?> capabilities,
    required Set<String> talkFeatures,
    required this.chatReadPrivacy,
    required Set<String> notificationPushFeatures,
  }) : capabilities = UnmodifiableMapView(capabilities),
       namespaces = Set<String>.unmodifiable(capabilities.keys),
       talkFeatures = Set<String>.unmodifiable(talkFeatures),
       notificationPushFeatures = Set<String>.unmodifiable(
         notificationPushFeatures,
       );

  factory CapabilitySnapshot.fromJson(
    Object? json, {
    required CapabilityContext context,
  }) {
    const code = TalkProtocolErrorCode.invalidCapabilities;
    final root = requireObject(json, path: r'$', code: code);
    final ocs = requireObject(root['ocs'], path: r'$.ocs', code: code);
    final meta = requireObject(ocs['meta'], path: r'$.ocs.meta', code: code);
    final status = requireString(
      meta['status'],
      path: r'$.ocs.meta.status',
      code: code,
    );
    final statusCode = requireInt(
      meta['statuscode'],
      path: r'$.ocs.meta.statuscode',
      code: code,
      minimum: 0,
      maximum: 999,
    );
    requireString(
      meta['message'],
      path: r'$.ocs.meta.message',
      code: code,
      maxLength: 4096,
    );
    if (status != 'ok' || statusCode != 200) {
      protocolFailure(TalkProtocolErrorCode.ocsFailure, r'$.ocs.meta');
    }

    final data = requireObject(ocs['data'], path: r'$.ocs.data', code: code);
    final version = NextcloudVersion.fromJson(data['version']);
    final frozen = freezeJson(data['capabilities']);
    if (frozen is! Map<String, Object?>) {
      protocolFailure(code, r'$.ocs.data.capabilities');
    }
    final capabilities = frozen;

    var talkFeatures = const <String>{};
    ChatReadPrivacy? chatReadPrivacy;
    final rawSpreed = capabilities['spreed'];
    if (rawSpreed != null) {
      final spreed = requireObject(
        rawSpreed,
        path: r'$.ocs.data.capabilities.spreed',
        code: code,
      );
      final rawFeatures = spreed['features'];
      if (rawFeatures != null) {
        talkFeatures = requireUniqueStringSet(
          rawFeatures,
          path: r'$.ocs.data.capabilities.spreed.features',
          code: code,
        );
      }

      final rawConfig = spreed['config'];
      if (rawConfig != null) {
        final config = requireObject(
          rawConfig,
          path: r'$.ocs.data.capabilities.spreed.config',
          code: code,
        );
        final rawChat = config['chat'];
        if (rawChat != null) {
          final chat = requireObject(
            rawChat,
            path: r'$.ocs.data.capabilities.spreed.config.chat',
            code: code,
          );
          if (chat.containsKey('read-privacy')) {
            final path =
                r'$.ocs.data.capabilities.spreed.config.chat.read-privacy';
            chatReadPrivacy = switch (requireInt(
              chat['read-privacy'],
              path: path,
              code: code,
            )) {
              0 => ChatReadPrivacy.public,
              1 => ChatReadPrivacy.private,
              _ => protocolFailure(code, path),
            };
          }
        }
      }
    }

    var notificationPushFeatures = const <String>{};
    final rawNotifications = capabilities['notifications'];
    if (rawNotifications != null) {
      final notifications = requireObject(
        rawNotifications,
        path: r'$.ocs.data.capabilities.notifications',
        code: code,
      );
      final rawPush = notifications['push'];
      if (rawPush != null) {
        notificationPushFeatures = requireUniqueStringSet(
          rawPush,
          path: r'$.ocs.data.capabilities.notifications.push',
          code: code,
        );
      }
    }

    return CapabilitySnapshot._(
      context: context,
      version: version,
      capabilities: capabilities,
      talkFeatures: talkFeatures,
      chatReadPrivacy: chatReadPrivacy,
      notificationPushFeatures: notificationPushFeatures,
    );
  }

  final CapabilityContext context;
  final NextcloudVersion version;
  final Map<String, Object?> capabilities;
  final Set<String> namespaces;
  final Set<String> talkFeatures;
  final ChatReadPrivacy? chatReadPrivacy;
  final Set<String> notificationPushFeatures;

  bool get hasTalk => namespaces.contains('spreed');

  bool supportsTalk(String feature) => talkFeatures.contains(feature);

  bool supportsNotificationPush(String feature) =>
      notificationPushFeatures.contains(feature);

  @override
  String toString() =>
      'CapabilitySnapshot(context: ${context.name}, '
      'namespaces: ${namespaces.length}, talkFeatures: ${talkFeatures.length})';
}
