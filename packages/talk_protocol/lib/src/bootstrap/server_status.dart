import '../json_value.dart';
import '../protocol_exception.dart';

/// Conditions that prevent account onboarding on a Nextcloud server.
enum ServerStatusBlocker {
  notInstalled('not-installed'),
  maintenance('maintenance'),
  databaseUpgradeRequired('database-upgrade-required');

  const ServerStatusBlocker(this.wireName);

  final String wireName;
}

/// Validated data from the public Nextcloud `status.php` endpoint.
final class ServerStatus {
  const ServerStatus({
    required this.installed,
    required this.maintenance,
    required this.needsDatabaseUpgrade,
    required this.version,
    required this.versionString,
    required this.edition,
    required this.productName,
    required this.extendedSupport,
  });

  factory ServerStatus.fromJson(Object? json) {
    const code = TalkProtocolErrorCode.invalidServerStatus;
    final value = requireObject(json, path: r'$', code: code);
    final installed = requireBool(
      value['installed'],
      path: r'$.installed',
      code: code,
    );
    final maintenance = requireBool(
      value['maintenance'],
      path: r'$.maintenance',
      code: code,
    );
    final needsDatabaseUpgrade = requireBool(
      value['needsDbUpgrade'],
      path: r'$.needsDbUpgrade',
      code: code,
    );
    final version = requireString(
      value['version'],
      path: r'$.version',
      code: code,
      minLength: 1,
      maxLength: 64,
    );
    final versionString = requireString(
      value['versionstring'],
      path: r'$.versionstring',
      code: code,
      minLength: 1,
      maxLength: 128,
    );
    final edition = requireString(
      value['edition'],
      path: r'$.edition',
      code: code,
      maxLength: 128,
    );
    final productName = requireString(
      value['productname'],
      path: r'$.productname',
      code: code,
      minLength: 1,
      maxLength: 256,
    );
    final rawExtendedSupport = value['extendedSupport'];
    final extendedSupport = rawExtendedSupport == null
        ? null
        : requireBool(
            rawExtendedSupport,
            path: r'$.extendedSupport',
            code: code,
          );
    return ServerStatus(
      installed: installed,
      maintenance: maintenance,
      needsDatabaseUpgrade: needsDatabaseUpgrade,
      version: version,
      versionString: versionString,
      edition: edition,
      productName: productName,
      extendedSupport: extendedSupport,
    );
  }

  final bool installed;
  final bool maintenance;
  final bool needsDatabaseUpgrade;
  final String version;
  final String versionString;
  final String edition;
  final String productName;
  final bool? extendedSupport;

  Set<ServerStatusBlocker> get blockers => Set.unmodifiable({
    if (!installed) ServerStatusBlocker.notInstalled,
    if (maintenance) ServerStatusBlocker.maintenance,
    if (needsDatabaseUpgrade) ServerStatusBlocker.databaseUpgradeRequired,
  });

  bool get isReady => blockers.isEmpty;
}
