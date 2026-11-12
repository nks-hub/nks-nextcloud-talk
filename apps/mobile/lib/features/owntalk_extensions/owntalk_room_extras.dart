import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import 'owntalk_extensions_service.dart';
import 'owntalk_settings_store.dart';

/// How often an open conversation re-reads the shared settings. A matching
/// `ETag` makes almost every one of these a bodiless `304`.
const Duration ownTalkSettingsPollInterval = Duration(seconds: 60);

/// What the extension currently says about one conversation.
final class OwnTalkRoomExtras {
  const OwnTalkRoomExtras({this.capability, this.settings});

  /// Nothing known and nothing to show: no extension, or not read yet.
  static const OwnTalkRoomExtras none = OwnTalkRoomExtras();

  /// Set once the server's capability has been read and offers the extension.
  /// `null` before that, and for servers without it.
  final OwnTalkExtensionsCapability? capability;

  /// The last known document, possibly from the on-disk cache.
  final OwnTalkRoomSettings? settings;

  bool get available => capability != null;

  bool get canEdit => capability != null && settings?.canEdit == true;

  /// The shared value of [field], or `null` when unset or when the server no
  /// longer supports the feature behind it.
  String? valueOf(OwnTalkSettingField field) {
    final known = capability;
    if (known != null && !known.supportsField(field)) {
      return null;
    }
    return settings?[field];
  }

  @override
  bool operator ==(Object other) =>
      other is OwnTalkRoomExtras &&
      other.capability == capability &&
      other.settings == settings;

  @override
  int get hashCode => Object.hash(capability, settings);
}

/// Overridable so tests need not wait a real minute.
final ownTalkSettingsPollIntervalProvider = Provider<Duration>(
  (ref) => ownTalkSettingsPollInterval,
);

final ownTalkSettingsStoreProvider = FutureProvider<OwnTalkSettingsStore>((
  ref,
) {
  return OwnTalkSettingsStore.openApplicationSupport();
});

/// Fetches, caches and polls the shared settings of one conversation while
/// something is watching it. Without the capability it never requests an
/// extension endpoint, and a failure leaves what is already shown in place.
final class OwnTalkRoomController
    extends AutoDisposeFamilyNotifier<OwnTalkRoomExtras, OwnTalkRoomKey> {
  Timer? _timer;
  bool _disposed = false;

  /// The server answered the capability read without the extension.
  bool _absent = false;
  Future<void> _tail = Future<void>.value();

  OwnTalkRoomKey get _key => arg;

  @override
  OwnTalkRoomExtras build(OwnTalkRoomKey arg) {
    _disposed = false;
    _absent = false;
    final resumes = ref
        .read(appLifecycleResumeEventsProvider)
        .listen((_) => unawaited(refresh()));
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      unawaited(resumes.cancel());
    });
    unawaited(_start());
    return OwnTalkRoomExtras.none;
  }

  Future<void> _start() async {
    final store = await _store();
    final cached = await _guard(() => store?.read(_key));
    if (cached != null) {
      _set(OwnTalkRoomExtras(settings: cached));
    }
    await refresh();
  }

  /// Reads the capability and then the document, once. Safe to call at any
  /// time; calls run one after another.
  Future<void> refresh() => _enqueue(_refresh);

  Future<void> _refresh() async {
    if (_disposed) {
      return;
    }
    try {
      final service = ref.read(ownTalkExtensionsServiceProvider);
      final capability = await service.capability(_key.accountId);
      if (capability == null) {
        _absent = true;
        await _dropAccountCache();
        _set(OwnTalkRoomExtras.none);
        return;
      }
      _absent = false;
      _set(OwnTalkRoomExtras(capability: capability, settings: state.settings));
      final result = await service.fetch(
        accountId: _key.accountId,
        roomToken: _key.roomToken,
        knownRevision: state.settings?.revision,
      );
      switch (result) {
        case OwnTalkSettingsLoaded(:final document):
          await _adopt(document, capability);
        case OwnTalkSettingsNotModified():
          break;
        case OwnTalkSettingsMissing():
          await _forget(capability);
        case OwnTalkSettingsFetchFailure(:final kind):
          if (kind == OwnTalkExtensionsFailureKind.forbidden) {
            // Two membership sources disagree: show nothing rather than guess.
            await _forget(capability);
          }
      }
    } on Object {
      // Network, 503, credential and cache problems keep what is shown; the
      // next tick retries without any UI.
    } finally {
      _schedule();
    }
  }

  Future<void> _forget(OwnTalkExtensionsCapability capability) async {
    await _guard(() async => (await _store())?.remove(_key));
    _set(OwnTalkRoomExtras(capability: capability));
  }

  void _set(OwnTalkRoomExtras value) {
    if (!_disposed) {
      state = value;
    }
  }

  /// Applies a merge patch on top of the revision currently shown. A `412`
  /// still updates the shown document, because it carries the server's.
  Future<OwnTalkSettingsUpdateResult> save(
    Map<OwnTalkSettingField, String?> changes,
  ) {
    final completer = Completer<OwnTalkSettingsUpdateResult>();
    unawaited(
      _enqueue(() async {
        try {
          final capability = state.capability;
          if (capability == null) {
            throw const OwnTalkExtensionsException(
              OwnTalkExtensionsError.unavailable,
            );
          }
          final result = await ref
              .read(ownTalkExtensionsServiceProvider)
              .update(
                accountId: _key.accountId,
                roomToken: _key.roomToken,
                changes: changes,
                baseRevision: state.settings?.revision ?? 0,
              );
          switch (result) {
            case OwnTalkSettingsSaved(:final document):
              await _adopt(document, capability);
            case OwnTalkSettingsConflict(:final current):
              await _adopt(current, capability);
            case OwnTalkSettingsUpdateFailure():
              break;
          }
          completer.complete(result);
        } on Object catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      }),
    );
    return completer.future;
  }

  Future<void> _adopt(
    OwnTalkRoomSettings document,
    OwnTalkExtensionsCapability capability,
  ) async {
    _set(OwnTalkRoomExtras(capability: capability, settings: document));
    await _guard(() async => (await _store())?.write(_key, document));
  }

  Future<void> _dropAccountCache() =>
      _guard(() async => (await _store())?.removeAccount(_key.accountId));

  void _schedule() {
    _timer?.cancel();
    if (_disposed || _absent) {
      return;
    }
    _timer = Timer(ref.read(ownTalkSettingsPollIntervalProvider), () {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle == AppLifecycleState.resumed || lifecycle == null) {
        unawaited(refresh());
      } else {
        _schedule();
      }
    });
  }

  Future<OwnTalkSettingsStore?> _store() async {
    try {
      return await ref.read(ownTalkSettingsStoreProvider.future);
    } on Object {
      return null;
    }
  }

  /// The cache is an optimisation; a broken disk must not break the chat.
  Future<T?> _guard<T>(FutureOr<T?> Function() action) async {
    try {
      return await action();
    } on Object {
      return null;
    }
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

final ownTalkRoomExtrasProvider = NotifierProvider.autoDispose
    .family<OwnTalkRoomController, OwnTalkRoomExtras, OwnTalkRoomKey>(
      OwnTalkRoomController.new,
    );
