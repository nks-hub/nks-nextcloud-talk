// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import 'owntalk_extensions_service.dart';
import 'owntalk_settings_store.dart';

/// Whether a conversation can carry shared settings at all, decided before any
/// request is made: a Talk one-to-one (1), group (2) or public (3)
/// conversation that is not federated. Changelog, note-to-self and former
/// one-to-one conversations are never polled.
bool ownTalkConversationCanShare({
  required int roomType,
  required String rawJson,
}) {
  if (roomType != 1 && roomType != 2 && roomType != 3) {
    return false;
  }
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is Map<String, Object?>) {
      final remoteServer = decoded['remoteServer'];
      return !(remoteServer is String && remoteServer.trim().isNotEmpty);
    }
  } on FormatException {
    return false;
  }
  return false;
}

/// How often an open conversation re-reads the shared settings. A matching
/// `ETag` makes almost every one of these a bodiless `304`.
const Duration ownTalkSettingsPollInterval = Duration(seconds: 60);

/// The longest pause between two polls while the server keeps answering `429`.
const Duration ownTalkSettingsMaximumBackoff = Duration(minutes: 10);

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

/// How long writes are collected before one silent chat message announces
/// them to the room.
const Duration ownTalkAppearanceNoticeWindow = Duration(seconds: 10);

/// Overridable so tests need not wait ten real seconds.
final ownTalkAppearanceNoticeWindowProvider = Provider<Duration>(
  (ref) => ownTalkAppearanceNoticeWindow,
);

/// Sends the silent "the look changed" chat message for shared-appearance
/// writes, one per conversation per [window]: writes that land while a notice
/// is pending only raise the revision it carries.
///
/// Lives outside the per-room controller, which goes away when the user leaves
/// the chat, so a notice queued by the last write before leaving still goes
/// out. Best effort: a failed post is dropped, never retried and never shown.
final class OwnTalkAppearanceNoticer {
  OwnTalkAppearanceNoticer({
    required this.window,
    required Future<void> Function(
      OwnTalkRoomKey key,
      int revision,
      String message,
    )
    send,
  }) : _send = send;

  final Duration window;
  final Future<void> Function(OwnTalkRoomKey key, int revision, String message)
  _send;
  final Map<OwnTalkRoomKey, _PendingNotice> _pending =
      <OwnTalkRoomKey, _PendingNotice>{};

  void announce(OwnTalkRoomKey key, int revision, String message) {
    final pending = _pending[key];
    if (pending != null) {
      if (revision > pending.revision) {
        pending.revision = revision;
      }
      pending.message = message;
      return;
    }
    final created = _PendingNotice(revision, message);
    created.timer = Timer(window, () {
      _pending.remove(key);
      unawaited(
        _send(
          key,
          created.revision,
          created.message,
        ).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    });
    _pending[key] = created;
  }

  void dispose() {
    for (final pending in _pending.values) {
      pending.timer?.cancel();
    }
    _pending.clear();
  }
}

final class _PendingNotice {
  _PendingNotice(this.revision, this.message);

  int revision;
  String message;
  Timer? timer;
}

final ownTalkAppearanceNoticerProvider = Provider<OwnTalkAppearanceNoticer>((
  ref,
) {
  final noticer = OwnTalkAppearanceNoticer(
    window: ref.watch(ownTalkAppearanceNoticeWindowProvider),
    send: (key, revision, message) => ref
        .read(ownTalkExtensionsServiceProvider)
        .announceAppearanceChange(
          accountId: key.accountId,
          roomToken: key.roomToken,
          revision: revision,
          message: message,
        ),
  );
  ref.onDispose(noticer.dispose);
  return noticer;
});

/// Spots the chat messages that announce a shared-appearance change and
/// arrived after the list was first seen, so scrolling back through history
/// never counts as news.
final class OwnTalkAppearanceMarkerWatch {
  int? _baseline;

  /// The `referenceId`s of announcing messages in [messages] newer than every
  /// message seen so far. Feed it each emission of the room's message list.
  List<String> fresh(Iterable<({int messageId, String referenceId})> messages) {
    final baseline = _baseline;
    final markers = <String>[];
    var highest = baseline ?? 0;
    for (final message in messages) {
      if (message.messageId > highest) {
        highest = message.messageId;
      }
      if (baseline != null &&
          message.messageId > baseline &&
          isOwnTalkAppearanceReferenceId(message.referenceId)) {
        markers.add(message.referenceId);
      }
    }
    _baseline = highest;
    return markers;
  }
}

/// Hands a signal pushed over [accountId]'s `notify_push` socket to the
/// controller of that account and room, when one is alive. A room nobody is
/// looking at needs nothing: it reads the document when it is opened.
void deliverOwnTalkRoomSettingsSignal(
  Ref ref,
  String accountId,
  OwnTalkRoomSettingsSignal signal,
) {
  final provider = ownTalkRoomExtrasProvider((
    accountId: accountId,
    roomToken: signal.roomToken.value,
  ));
  if (ref.exists(provider)) {
    unawaited(ref.read(provider.notifier).refreshIfNewer(signal.revision));
  }
}

/// Fetches, caches and polls the shared settings of one conversation while
/// something is watching it. Without the capability it never requests an
/// extension endpoint, and a failure leaves what is already shown in place.
final class OwnTalkRoomController
    extends AutoDisposeFamilyNotifier<OwnTalkRoomExtras, OwnTalkRoomKey> {
  Timer? _timer;
  bool _disposed = false;

  /// The server answered the capability read without the extension.
  bool _absent = false;

  /// The `ETag` that came with the shown document, exactly as received. It
  /// goes back as `If-None-Match` and is never rebuilt from the revision,
  /// because the server also derives it from the caller's permissions.
  String? _etag;

  /// Pause before the next poll; grows while the server answers `429`.
  Duration? _pause;
  Future<void> _tail = Future<void>.value();

  OwnTalkRoomKey get _key => arg;

  @override
  OwnTalkRoomExtras build(OwnTalkRoomKey arg) {
    _disposed = false;
    _absent = false;
    _etag = null;
    _pause = null;
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
    await _enqueue(_loadCache);
    await refresh();
  }

  /// Runs in the queue, so it can tell whether a network answer got there
  /// first; the cache only fills a gap and never replaces newer state.
  Future<void> _loadCache() async {
    final cached = await _guard(() async => (await _store())?.readEntry(_key));
    if (cached == null || _absent || state.settings != null) {
      return;
    }
    _etag = cached.etag;
    _set(
      OwnTalkRoomExtras(
        capability: state.capability,
        settings: cached.document,
      ),
    );
  }

  /// Reads the capability and then the document, once. Safe to call at any
  /// time; calls run one after another.
  Future<void> refresh() => _enqueue(_refresh);

  /// [refresh], unless the shown document already is at [revision] or newer.
  /// The check runs when the call's turn in the queue comes, so a write that
  /// is still in flight is taken into account.
  Future<void> refreshIfNewer(int revision) => _enqueue(() async {
    final shown = state.settings?.revision;
    if (shown != null && shown >= revision) {
      return;
    }
    await _refresh();
  });

  /// Reacts to chat messages that announce a shared-appearance change, given
  /// as their `referenceId`s. Only ever reads: a refresh sends nothing.
  Future<void> refreshForAppearanceMarkers(Iterable<String> referenceIds) {
    int? newest;
    for (final id in referenceIds) {
      final revision = int.tryParse(
        id.substring(ownTalkAppearanceReferencePrefix.length),
      );
      if (revision == null) {
        return refresh();
      }
      if (newest == null || revision > newest) {
        newest = revision;
      }
    }
    return newest == null ? Future<void>.value() : refreshIfNewer(newest);
  }

  Future<void> _refresh() async {
    if (_disposed) {
      return;
    }
    var retry = true;
    var limited = false;
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
        knownEtag: state.settings == null ? null : _etag,
      );
      switch (result) {
        case OwnTalkSettingsLoaded(:final document, :final etag):
          await _adopt(document, capability, etag);
        case OwnTalkSettingsNotModified():
          break;
        case OwnTalkSettingsMissing():
          await _forget(capability);
        case OwnTalkSettingsFetchFailure(:final kind, retryAfter: final wait):
          switch (kind) {
            case OwnTalkExtensionsFailureKind.forbidden:
              // Two membership sources disagree: show nothing rather than
              // guess.
              await _forget(capability);
            case OwnTalkExtensionsFailureKind.reauthenticationRequired:
              retry = false;
            case OwnTalkExtensionsFailureKind.rateLimited:
              limited = true;
              _backOff(wait);
            default:
              break;
          }
      }
    } on OwnTalkExtensionsException catch (error) {
      // Network, 503 and rate-limit problems keep what is shown. A rejected
      // login will not heal by polling. Only a transient failure, or a server
      // already known to offer the extension, is worth another silent try.
      if (error.code == OwnTalkExtensionsError.rateLimited) {
        limited = true;
        _backOff(error.retryAfter);
      }
      retry =
          error.code != OwnTalkExtensionsError.reauthenticationRequired &&
          (error.code == OwnTalkExtensionsError.network || state.available);
    } on Object {
      retry = state.available;
    } finally {
      if (!limited) {
        _pause = null;
      }
      if (retry) {
        _schedule();
      } else {
        _timer?.cancel();
      }
    }
  }

  /// Doubles the pause up to [ownTalkSettingsMaximumBackoff], or waits as long
  /// as the server asked, but never less than the normal interval.
  void _backOff(Duration? retryAfter) {
    final base = ref.read(ownTalkSettingsPollIntervalProvider);
    final ceiling = ownTalkSettingsMaximumBackoff > base
        ? ownTalkSettingsMaximumBackoff
        : base;
    final wanted = retryAfter ?? (_pause ?? base) * 2;
    _pause = wanted < base
        ? base
        : wanted > ceiling
        ? ceiling
        : wanted;
  }

  Future<void> _forget(OwnTalkExtensionsCapability capability) async {
    _etag = null;
    await _guard(() async => (await _store())?.remove(_key));
    _set(OwnTalkRoomExtras(capability: capability));
  }

  void _set(OwnTalkRoomExtras value) {
    if (!_disposed && value != state) {
      state = value;
    }
  }

  /// Applies a merge patch on top of [baseRevision], the revision the user
  /// saw when they started editing; it defaults to the one shown now. A `412`
  /// still updates the shown document, because it carries the server's.
  ///
  /// With [announcement], a successful write also queues the silent chat
  /// message that tells the other participants' clients to re-read.
  Future<OwnTalkSettingsUpdateResult> save(
    Map<OwnTalkSettingField, String?> changes, {
    int? baseRevision,
    String? announcement,
  }) => _write(
    (service, base) => service.update(
      accountId: _key.accountId,
      roomToken: _key.roomToken,
      changes: changes,
      baseRevision: base,
    ),
    baseRevision,
    announcement,
  );

  /// Uploads a background image through the same queue, revision rule and
  /// conflict handling as [save]; it changes `chat.backgroundImage`.
  Future<OwnTalkSettingsUpdateResult> uploadImage({
    required Uint8List bytes,
    required String contentType,
    int? baseRevision,
    String? announcement,
  }) => _write(
    (service, base) => service.uploadImage(
      accountId: _key.accountId,
      roomToken: _key.roomToken,
      bytes: bytes,
      contentType: contentType,
      baseRevision: base,
    ),
    baseRevision,
    announcement,
  );

  Future<OwnTalkSettingsUpdateResult> _write(
    Future<OwnTalkSettingsUpdateResult> Function(
      OwnTalkExtensionsService service,
      int baseRevision,
    )
    run,
    int? baseRevision,
    String? announcement,
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
          final result = await run(
            ref.read(ownTalkExtensionsServiceProvider),
            baseRevision ?? state.settings?.revision ?? 0,
          );
          switch (result) {
            case OwnTalkSettingsSaved(:final document, :final etag):
              await _adopt(document, capability, etag);
              if (announcement != null) {
                ref
                    .read(ownTalkAppearanceNoticerProvider)
                    .announce(_key, document.revision, announcement);
              }
            case OwnTalkSettingsConflict(:final current):
              await _adopt(current, capability, null);
            case OwnTalkSettingsUpdateFailure(:final kind):
              if (kind == OwnTalkExtensionsFailureKind.forbidden) {
                // The edit right changed under the shown document; read it
                // again unconditionally rather than trust a `304`.
                _etag = null;
                unawaited(refresh());
              }
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
    String? etag,
  ) async {
    _etag = etag;
    _set(OwnTalkRoomExtras(capability: capability, settings: document));
    await _guard(
      () async => (await _store())?.write(_key, document, etag: etag),
    );
  }

  Future<void> _dropAccountCache() =>
      _guard(() async => (await _store())?.removeAccount(_key.accountId));

  void _schedule() {
    _timer?.cancel();
    if (_disposed || _absent) {
      return;
    }
    _timer = Timer(_pause ?? ref.read(ownTalkSettingsPollIntervalProvider), () {
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
