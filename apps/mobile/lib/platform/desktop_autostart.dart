import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _channelName = 'com.nkshub.nextcloudtalk/desktop_autostart';

abstract interface class DesktopAutostart {
  Future<bool> isSupported();

  Future<bool> isEnabled();

  Future<bool> setEnabled(bool enabled);
}

final class MethodChannelDesktopAutostart implements DesktopAutostart {
  const MethodChannelDesktopAutostart({
    this._channel = const MethodChannel(_channelName),
  });

  final MethodChannel _channel;

  @override
  Future<bool> isSupported() => _invokeBool('isSupported');

  @override
  Future<bool> isEnabled() => _invokeBool('isEnabled');

  @override
  Future<bool> setEnabled(bool enabled) {
    return _invokeBool('setEnabled', <String, Object?>{'enabled': enabled});
  }

  Future<bool> _invokeBool(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final value = await _channel.invokeMethod<bool>(method, arguments);
    if (value == null) {
      throw const FormatException('Desktop autostart returned no state.');
    }
    return value;
  }
}

@immutable
final class DesktopAutostartState {
  const DesktopAutostartState({
    required this.supported,
    required this.enabled,
    required this.busy,
    required this.failed,
  });

  const DesktopAutostartState.loading()
    : supported = null,
      enabled = null,
      busy = true,
      failed = false;

  final bool? supported;
  final bool? enabled;
  final bool busy;
  final bool failed;

  DesktopAutostartState copyWith({
    bool? supported,
    bool? enabled,
    bool? busy,
    bool? failed,
  }) {
    return DesktopAutostartState(
      supported: supported ?? this.supported,
      enabled: enabled ?? this.enabled,
      busy: busy ?? this.busy,
      failed: failed ?? this.failed,
    );
  }
}

bool get isDesktopAutostartPlatform {
  if (kIsWeb) {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
}

final desktopAutostartProvider = Provider<DesktopAutostart>((ref) {
  return const MethodChannelDesktopAutostart();
});

final desktopAutostartHostProvider = Provider<bool>((ref) {
  return isDesktopAutostartPlatform;
});

final desktopAutostartStateProvider =
    NotifierProvider<DesktopAutostartController, DesktopAutostartState>(
      DesktopAutostartController.new,
    );

final class DesktopAutostartController extends Notifier<DesktopAutostartState> {
  @override
  DesktopAutostartState build() {
    if (!ref.watch(desktopAutostartHostProvider)) {
      return const DesktopAutostartState(
        supported: false,
        enabled: false,
        busy: false,
        failed: false,
      );
    }
    unawaited(Future<void>.microtask(refresh));
    return const DesktopAutostartState.loading();
  }

  Future<void> refresh() async {
    final previous = state;
    state = previous.copyWith(busy: true, failed: false);
    try {
      final platform = ref.read(desktopAutostartProvider);
      final supported = await platform.isSupported();
      if (!supported) {
        state = const DesktopAutostartState(
          supported: false,
          enabled: false,
          busy: false,
          failed: false,
        );
        return;
      }
      final enabled = await platform.isEnabled();
      state = DesktopAutostartState(
        supported: true,
        enabled: enabled,
        busy: false,
        failed: false,
      );
    } on Object {
      state = previous.copyWith(busy: false, failed: true);
    }
  }

  Future<bool> setEnabled(bool enabled) async {
    if (state.busy || state.supported != true) {
      return false;
    }
    final previous = state;
    state = previous.copyWith(busy: true, failed: false);
    try {
      final platform = ref.read(desktopAutostartProvider);
      final applied = await platform.setEnabled(enabled);
      final actual = await platform.isEnabled();
      if (applied != enabled || actual != enabled) {
        state = previous.copyWith(busy: false, failed: true);
        return false;
      }
      state = DesktopAutostartState(
        supported: true,
        enabled: actual,
        busy: false,
        failed: false,
      );
      return true;
    } on Object {
      state = previous.copyWith(busy: false, failed: true);
      return false;
    }
  }
}
