import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where this build came from, as far as the update check needs to know.
///
/// Only Android can answer: a desktop build is never installed by a shop, and
/// an iOS build always is.
enum AppInstallSource {
  /// Installed by a shop that updates it — Play and the like.
  store,

  /// Installed from a file somebody downloaded, so nothing updates it.
  sideloaded,

  /// The system would not say, or was not asked yet. Read as [store]
  /// everywhere it matters: offering a download beside a shop is the mistake
  /// worth avoiding, and saying nothing is the harmless half of being wrong.
  unknown,
}

/// Applications that install and then keep a build up to date. A build from
/// any of these must never be offered a download of its own.
const storeInstallerPackages = <String>{
  // Google Play, and the older name its installs still carry.
  'com.android.vending',
  'com.google.android.feedback',
  // The other shops a build of this could plausibly arrive from.
  'com.amazon.venezia',
  'com.huawei.appmarket',
  'org.fdroid.fdroid',
  'com.sec.android.app.samsungapps',
};

/// Asks the platform who installed this build.
final class AppInstallSourceReader {
  const AppInstallSourceReader({
    this.channel = const MethodChannel(channelName),
  });

  static const channelName = 'com.nkshub.nextcloudtalk/install_source';
  static const installingPackageMethod = 'installingPackage';

  final MethodChannel channel;

  Future<AppInstallSource> read() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return AppInstallSource.unknown;
    }
    try {
      final installer = await channel.invokeMethod<String>(
        installingPackageMethod,
      );
      return classifyInstaller(installer);
    } on Object {
      return AppInstallSource.unknown;
    }
  }
}

/// A package name nobody recognises is a build installed by hand; no name at
/// all is a question the system refused, which stays [AppInstallSource.unknown].
AppInstallSource classifyInstaller(String? installingPackage) {
  final name = installingPackage?.trim();
  if (name == null || name.isEmpty) {
    return AppInstallSource.unknown;
  }
  return storeInstallerPackages.contains(name)
      ? AppInstallSource.store
      : AppInstallSource.sideloaded;
}
