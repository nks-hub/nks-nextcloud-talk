import 'package:geolocator/geolocator.dart';

abstract interface class AppSettingsOpener {
  Future<bool> open();
}

final class GeolocatorAppSettingsOpener implements AppSettingsOpener {
  const GeolocatorAppSettingsOpener();

  @override
  Future<bool> open() => Geolocator.openAppSettings();
}
