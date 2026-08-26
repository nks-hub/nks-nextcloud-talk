import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

enum AndroidWebPushEventType {
  endpoint,
  activation,
  message,
  registrationFailed,
  unregistered,
  temporaryUnavailable,
}

enum AndroidWebPushRegistrationStatus { created, reregistered }

enum AndroidWebPushRegistrationPhase {
  registering,
  active,
  serverRevokePending,
  unregistered,
  nativeUnregistering,
  retired,
}

enum AndroidNotificationPermission { notDetermined, denied, granted }

enum AndroidNotificationActionKind { reply, markRead }

enum AndroidNotificationActionOutcome { completed, failed }

abstract interface class AndroidWebPushPlatform {
  Stream<int> get eventsAvailable;

  Stream<AndroidNotificationOpen> get notificationOpened;

  Future<AndroidWebPushAvailability> getAvailability();

  Future<AndroidWebPushRegistrationState> getRegistrationState({
    required String accountId,
  });

  Future<AndroidNotificationPermission> getNotificationPermission();

  Future<AndroidNotificationPermission> requestNotificationPermission();

  Future<AndroidNotificationOpen?> getLaunchNotification();

  Future<AndroidWebPushRegistrationResult> register({
    required String accountId,
    required int generation,
    required String vapidPublicKey,
  });

  Future<AndroidWebPushCommitResult> commitEndpoint({
    required String accountId,
    required int generation,
    required String eventId,
  });

  /// Durably moves this account's live native generations behind the server
  /// revocation barrier and returns every generation awaiting confirmation.
  Future<List<int>> prepareServerRevocation({required String accountId});

  Future<int> retireAfterServerRevocation({
    required String accountId,
    required int generation,
  });

  Future<int> pendingEventCount({required String accountId});

  Future<List<AndroidWebPushEvent>> drainEvents({
    required String accountId,
    int limit,
  });

  Future<int> acknowledge({
    required String accountId,
    required Iterable<String> eventIds,
  });

  /// Queued notification actions of exactly [accountId]. Each call counts as
  /// one attempt natively; an action that runs out of attempts is dropped from
  /// the queue and shown to the user as a failed notification.
  Future<List<AndroidNotificationAction>> drainNotificationActions({
    required String accountId,
    int limit,
  });

  /// Removes a queued action. [AndroidNotificationActionOutcome.completed]
  /// cancels its notification, `failed` replaces it with a visible failure.
  Future<bool> resolveNotificationAction({
    required String accountId,
    required String actionId,
    required AndroidNotificationActionOutcome outcome,
  });

  Future<void> dispose();
}

class AndroidNotificationAction {
  const AndroidNotificationAction({
    required this.id,
    required this.accountId,
    required this.kind,
    required this.notificationId,
    required this.roomToken,
    required this.replyText,
  });

  final String id;
  final String accountId;
  final AndroidNotificationActionKind kind;
  final int notificationId;
  final String roomToken;
  final String? replyText;

  factory AndroidNotificationAction.fromMap(Map<Object?, Object?> map) {
    final notificationId = _requiredInt(map, 'notificationId');
    final replyText = _optionalString(map, 'replyText');
    final kind = switch (_requiredString(map, 'kind')) {
      'REPLY' => AndroidNotificationActionKind.reply,
      'MARK_READ' => AndroidNotificationActionKind.markRead,
      _ => throw const FormatException(
        'Native notification action is invalid.',
      ),
    };
    if (notificationId <= 0 ||
        (kind == AndroidNotificationActionKind.reply &&
            (replyText == null || replyText.trim().isEmpty))) {
      throw const FormatException('Native notification action is invalid.');
    }
    return AndroidNotificationAction(
      id: _requiredString(map, 'id'),
      accountId: _requiredString(map, 'accountId'),
      kind: kind,
      notificationId: notificationId,
      roomToken: _requiredString(map, 'roomToken'),
      replyText: replyText,
    );
  }

  @override
  String toString() =>
      'AndroidNotificationAction(id: <redacted>, accountId: <redacted>, '
      'kind: ${kind.name}, notificationId: $notificationId, '
      'roomToken: <redacted>, replyText: <redacted>)';
}

class AndroidWebPushAvailability {
  const AndroidWebPushAvailability({
    required this.available,
    required this.playServicesAvailable,
  });

  final bool available;
  final bool playServicesAvailable;

  factory AndroidWebPushAvailability.fromMap(Map<Object?, Object?> map) {
    return AndroidWebPushAvailability(
      available: _requiredBool(map, 'available'),
      playServicesAvailable: _requiredBool(map, 'playServicesAvailable'),
    );
  }
}

class AndroidWebPushRegistrationResult {
  const AndroidWebPushRegistrationResult({
    required this.generation,
    required this.status,
  });

  final int generation;
  final AndroidWebPushRegistrationStatus status;

  factory AndroidWebPushRegistrationResult.fromMap(Map<Object?, Object?> map) {
    return AndroidWebPushRegistrationResult(
      generation: _requiredInt(map, 'generation'),
      status: AndroidWebPushRegistrationStatus.values.byName(
        _requiredString(map, 'status'),
      ),
    );
  }
}

class AndroidWebPushRegistrationState {
  const AndroidWebPushRegistrationState({
    required this.generation,
    required this.nextGeneration,
    required this.phase,
    required this.pendingEventCount,
  });

  final int? generation;
  final int nextGeneration;
  final AndroidWebPushRegistrationPhase? phase;
  final int pendingEventCount;

  factory AndroidWebPushRegistrationState.fromMap(Map<Object?, Object?> map) {
    final generation = _optionalInt(map, 'generation');
    final nextGeneration = _requiredInt(map, 'nextGeneration');
    final pendingEventCount = _requiredInt(map, 'pendingEventCount');
    final rawPhase = _optionalString(map, 'phase');
    if (generation != null && generation <= 0 ||
        nextGeneration <= 0 ||
        pendingEventCount < 0) {
      throw const FormatException(
        'Native push registration state has invalid counters.',
      );
    }
    return AndroidWebPushRegistrationState(
      generation: generation,
      nextGeneration: nextGeneration,
      phase: rawPhase == null ? null : _registrationPhase(rawPhase),
      pendingEventCount: pendingEventCount,
    );
  }
}

class AndroidNotificationOpen {
  const AndroidNotificationOpen({
    required this.accountId,
    required this.notificationId,
    required this.app,
    required this.type,
    required this.objectId,
  });

  final String accountId;
  final int notificationId;
  final String app;
  final String? type;
  final String? objectId;

  factory AndroidNotificationOpen.fromMap(Map<Object?, Object?> map) {
    final notificationId = _requiredInt(map, 'notificationId');
    if (notificationId <= 0) {
      throw const FormatException('Native notification id is invalid.');
    }
    return AndroidNotificationOpen(
      accountId: _requiredString(map, 'accountId'),
      notificationId: notificationId,
      app: _requiredString(map, 'app'),
      type: _optionalString(map, 'type'),
      objectId: _optionalString(map, 'objectId'),
    );
  }

  @override
  String toString() =>
      'AndroidNotificationOpen(accountId: <redacted>, notificationId: '
      '$notificationId, app: $app, type: $type, objectId: <redacted>)';
}

class AndroidWebPushCommitResult {
  const AndroidWebPushCommitResult({required this.serverRevokeGenerations});

  final List<int> serverRevokeGenerations;

  factory AndroidWebPushCommitResult.fromMap(Map<Object?, Object?> map) {
    final generations = map['serverRevokeGenerations'];
    if (generations is! List<Object?> ||
        generations.any((item) => item is! int)) {
      throw const FormatException(
        'Native push response has invalid server revoke generations.',
      );
    }
    return AndroidWebPushCommitResult(
      serverRevokeGenerations: generations.cast<int>(),
    );
  }
}

class AndroidWebPushEndpoint {
  const AndroidWebPushEndpoint({
    required this.url,
    required this.temporary,
    this.publicKey,
    this.authSecret,
  });

  final String url;
  final bool temporary;
  final String? publicKey;
  final String? authSecret;

  factory AndroidWebPushEndpoint.fromMap(Map<Object?, Object?> map) {
    return AndroidWebPushEndpoint(
      url: _requiredString(map, 'url'),
      temporary: _requiredBool(map, 'temporary'),
      publicKey: _optionalString(map, 'publicKey'),
      authSecret: _optionalString(map, 'authSecret'),
    );
  }

  @override
  String toString() =>
      'AndroidWebPushEndpoint(url: <redacted>, keys: <redacted>, '
      'temporary: $temporary)';
}

class AndroidWebPushEvent {
  const AndroidWebPushEvent({
    required this.id,
    required this.accountId,
    required this.generation,
    required this.type,
    required this.createdAt,
    required this.coalescedCount,
    required this.stale,
    this.endpoint,
    this.content,
    this.decrypted,
    this.payloadOversized = false,
    this.originalSize,
    this.failureReason,
  });

  final String id;
  final String accountId;
  final int generation;
  final AndroidWebPushEventType type;
  final DateTime createdAt;
  final int coalescedCount;
  final bool stale;
  final AndroidWebPushEndpoint? endpoint;
  final Uint8List? content;
  final bool? decrypted;
  final bool payloadOversized;
  final int? originalSize;
  final String? failureReason;

  factory AndroidWebPushEvent.fromMap(Map<Object?, Object?> map) {
    final endpointValue = map['endpoint'];
    final encodedContent = _optionalString(map, 'content');
    return AndroidWebPushEvent(
      id: _requiredString(map, 'id'),
      accountId: _requiredString(map, 'accountId'),
      generation: _requiredInt(map, 'generation'),
      type: AndroidWebPushEventType.values.byName(_requiredString(map, 'type')),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        _requiredInt(map, 'createdAtMillis'),
        isUtc: true,
      ),
      coalescedCount: _requiredInt(map, 'coalescedCount'),
      stale: _requiredBool(map, 'stale'),
      endpoint: endpointValue == null
          ? null
          : AndroidWebPushEndpoint.fromMap(_requiredMap(endpointValue)),
      content: encodedContent == null
          ? null
          : Uint8List.fromList(base64Decode(encodedContent)),
      decrypted: _optionalBool(map, 'decrypted'),
      payloadOversized: _optionalBool(map, 'payloadOversized') ?? false,
      originalSize: _optionalInt(map, 'originalSize'),
      failureReason: _optionalString(map, 'failureReason'),
    );
  }

  @override
  String toString() {
    return 'AndroidWebPushEvent(id: <redacted>, accountId: <redacted>, '
        'generation: $generation, type: ${type.name}, '
        'coalescedCount: $coalescedCount, stale: $stale, '
        'payload: <redacted>)';
  }
}

class AndroidWebPushBridge implements AndroidWebPushPlatform {
  AndroidWebPushBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'com.nkshub.nextcloudtalk/android_web_push';

  final MethodChannel _channel;
  final StreamController<int> _eventsAvailableController =
      StreamController<int>.broadcast();
  final StreamController<AndroidNotificationOpen>
  _notificationOpenedController = StreamController.broadcast();

  @override
  Stream<int> get eventsAvailable => _eventsAvailableController.stream;

  @override
  Stream<AndroidNotificationOpen> get notificationOpened =>
      _notificationOpenedController.stream;

  @override
  Future<AndroidWebPushAvailability> getAvailability() async {
    final response = await _invokeMap('getAvailability');
    return AndroidWebPushAvailability.fromMap(response);
  }

  @override
  Future<AndroidWebPushRegistrationState> getRegistrationState({
    required String accountId,
  }) async {
    final response = await _invokeMap('getRegistrationState', <String, Object>{
      'accountId': accountId,
    });
    return AndroidWebPushRegistrationState.fromMap(response);
  }

  @override
  Future<AndroidNotificationPermission> getNotificationPermission() async {
    final response = await _invokeMap('getNotificationPermission');
    return AndroidNotificationPermission.values.byName(
      _requiredString(response, 'status'),
    );
  }

  @override
  Future<AndroidNotificationPermission> requestNotificationPermission() async {
    final response = await _invokeMap('requestNotificationPermission');
    return AndroidNotificationPermission.values.byName(
      _requiredString(response, 'status'),
    );
  }

  @override
  Future<AndroidNotificationOpen?> getLaunchNotification() async {
    final response = await _channel.invokeMethod<Object?>(
      'getLaunchNotification',
    );
    if (response == null) {
      return null;
    }
    return AndroidNotificationOpen.fromMap(_requiredMap(response));
  }

  @override
  Future<AndroidWebPushRegistrationResult> register({
    required String accountId,
    required int generation,
    required String vapidPublicKey,
  }) async {
    final response = await _invokeMap('register', <String, Object>{
      'accountId': accountId,
      'generation': generation,
      'vapidPublicKey': vapidPublicKey,
    });
    return AndroidWebPushRegistrationResult.fromMap(response);
  }

  @override
  Future<AndroidWebPushCommitResult> commitEndpoint({
    required String accountId,
    required int generation,
    required String eventId,
  }) async {
    final response = await _invokeMap('commitEndpoint', <String, Object>{
      'accountId': accountId,
      'generation': generation,
      'eventId': eventId,
    });
    return AndroidWebPushCommitResult.fromMap(response);
  }

  @override
  Future<List<int>> prepareServerRevocation({required String accountId}) async {
    final response = await _invokeMap(
      'prepareServerRevocation',
      <String, Object>{'accountId': accountId},
    );
    final rawGenerations = response['generations'];
    if (rawGenerations is! List<Object?> ||
        rawGenerations.any((value) => value is! int || value <= 0)) {
      throw const FormatException(
        'Native push response has invalid pending generations.',
      );
    }
    final generations = rawGenerations.cast<int>().toSet().toList()..sort();
    if (generations.length != rawGenerations.length) {
      throw const FormatException(
        'Native push response has duplicate pending generations.',
      );
    }
    return generations;
  }

  @override
  Future<int> retireAfterServerRevocation({
    required String accountId,
    required int generation,
  }) async {
    final response = await _invokeMap(
      'retireAfterServerRevocation',
      <String, Object>{'accountId': accountId, 'generation': generation},
    );
    return _requiredInt(response, 'retiredCount');
  }

  @override
  Future<int> pendingEventCount({required String accountId}) async {
    final response = await _invokeMap('pendingEventCount', <String, Object>{
      'accountId': accountId,
    });
    return _requiredInt(response, 'count');
  }

  @override
  Future<List<AndroidWebPushEvent>> drainEvents({
    required String accountId,
    int limit = 50,
  }) async {
    final response = await _channel.invokeMethod<List<Object?>>(
      'drainEvents',
      <String, Object>{'accountId': accountId, 'limit': limit},
    );
    if (response == null) {
      throw const FormatException('Native push event list is missing.');
    }
    return response
        .map((event) => AndroidWebPushEvent.fromMap(_requiredMap(event)))
        .toList(growable: false);
  }

  @override
  Future<int> acknowledge({
    required String accountId,
    required Iterable<String> eventIds,
  }) async {
    final ids = eventIds.toList(growable: false);
    final response = await _invokeMap('acknowledge', <String, Object>{
      'accountId': accountId,
      'eventIds': ids,
    });
    return _requiredInt(response, 'removedCount');
  }

  @override
  Future<List<AndroidNotificationAction>> drainNotificationActions({
    required String accountId,
    int limit = 20,
  }) async {
    final response = await _channel.invokeMethod<List<Object?>>(
      'drainNotificationActions',
      <String, Object>{'accountId': accountId, 'limit': limit},
    );
    if (response == null) {
      throw const FormatException(
        'Native notification action list is missing.',
      );
    }
    return response
        .map(
          (action) => AndroidNotificationAction.fromMap(_requiredMap(action)),
        )
        .toList(growable: false);
  }

  @override
  Future<bool> resolveNotificationAction({
    required String accountId,
    required String actionId,
    required AndroidNotificationActionOutcome outcome,
  }) async {
    final response = await _invokeMap(
      'resolveNotificationAction',
      <String, Object>{
        'accountId': accountId,
        'actionId': actionId,
        'outcome': outcome.name,
      },
    );
    return _requiredBool(response, 'resolved');
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _eventsAvailableController.close();
    await _notificationOpenedController.close();
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    final arguments = _requiredMap(call.arguments);
    switch (call.method) {
      case 'eventsAvailable':
        _eventsAvailableController.add(_requiredInt(arguments, 'count'));
      case 'notificationOpened':
        _notificationOpenedController.add(
          AndroidNotificationOpen.fromMap(arguments),
        );
      default:
        throw MissingPluginException('Unknown Android Web Push callback.');
    }
  }

  Future<Map<Object?, Object?>> _invokeMap(
    String method, [
    Object? arguments,
  ]) async {
    final response = await _channel.invokeMethod<Object?>(method, arguments);
    return _requiredMap(response);
  }
}

AndroidWebPushRegistrationPhase _registrationPhase(String value) {
  return switch (value) {
    'REGISTERING' ||
    'registering' => AndroidWebPushRegistrationPhase.registering,
    'ACTIVE' || 'active' => AndroidWebPushRegistrationPhase.active,
    'SERVER_REVOKE_PENDING' || 'serverRevokePending' =>
      AndroidWebPushRegistrationPhase.serverRevokePending,
    'UNREGISTERED' ||
    'unregistered' => AndroidWebPushRegistrationPhase.unregistered,
    'NATIVE_UNREGISTERING' || 'nativeUnregistering' =>
      AndroidWebPushRegistrationPhase.nativeUnregistering,
    'RETIRED' || 'retired' => AndroidWebPushRegistrationPhase.retired,
    _ => throw const FormatException(
      'Native push registration phase is invalid.',
    ),
  };
}

Map<Object?, Object?> _requiredMap(Object? value) {
  if (value is Map<Object?, Object?>) {
    return value;
  }
  throw const FormatException('Native push response has an invalid shape.');
}

String _requiredString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Native push response is missing $key.');
}

String? _optionalString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null || value is String) {
    return value as String?;
  }
  throw FormatException('Native push response has an invalid $key.');
}

int _requiredInt(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is int) {
    return value;
  }
  throw FormatException('Native push response is missing $key.');
}

int? _optionalInt(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null || value is int) {
    return value as int?;
  }
  throw FormatException('Native push response has an invalid $key.');
}

bool _requiredBool(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is bool) {
    return value;
  }
  throw FormatException('Native push response is missing $key.');
}

bool? _optionalBool(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value == null || value is bool) {
    return value as bool?;
  }
  throw FormatException('Native push response has an invalid $key.');
}
