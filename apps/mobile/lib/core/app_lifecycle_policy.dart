import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

bool shouldRunForegroundSync(
  AppLifecycleState? state, {
  TargetPlatform? targetPlatform,
  bool? isWeb,
}) {
  if (state == null || state == AppLifecycleState.resumed) {
    return true;
  }
  if (isWeb ?? kIsWeb) {
    return false;
  }
  final platform = targetPlatform ?? defaultTargetPlatform;
  final desktop =
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.linux;
  return desktop &&
      state != AppLifecycleState.paused &&
      state != AppLifecycleState.detached;
}
