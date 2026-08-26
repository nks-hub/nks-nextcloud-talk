part of 'giphy.dart';

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const GiphyException(GiphyError.invalidResponse);
  }
  return value;
}

void _requirePositive(int value, String name) {
  if (value < 1) {
    throw ArgumentError.value(value, name, 'must be positive');
  }
}

String _boundedString(Object? value, {required int maximumLength}) {
  if (value is! String || value.length > maximumLength) {
    throw const GiphyException(GiphyError.invalidResponse);
  }
  return value;
}

Uri _uri(Object? value) {
  if (value is! String || value.length > 4096) {
    throw const GiphyException(GiphyError.invalidResponse);
  }
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.isAbsolute) {
    throw const GiphyException(GiphyError.invalidResponse);
  }
  return uri;
}

double? _referenceAspectRatio(Object? rawImages) {
  if (rawImages is! Map<String, Object?>) {
    return null;
  }
  for (final name in const <String>['fixed_width', 'original', 'downsized']) {
    final rawRendition = rawImages[name];
    if (rawRendition is! Map<String, Object?>) {
      continue;
    }
    final width = _referenceDimension(rawRendition['width']);
    final height = _referenceDimension(rawRendition['height']);
    if (width == null || height == null) {
      continue;
    }
    final ratio = width / height;
    if (ratio.isFinite && ratio >= 0.1 && ratio <= 10) {
      return ratio;
    }
  }
  return null;
}

double? _referenceDimension(Object? value) {
  final parsed = switch (value) {
    num() => value.toDouble(),
    String() => double.tryParse(value),
    _ => null,
  };
  if (parsed == null ||
      !parsed.isFinite ||
      parsed <= 0 ||
      parsed > _maximumGifLogicalDimension) {
    return null;
  }
  return parsed;
}

bool _isSafeThumbnail(ServerBase server, Uri uri) {
  if (!server.hasSameOrigin(uri) ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    return false;
  }
  final baseSegments = server.uri.pathSegments;
  for (final routePrefix in const <List<String>>[
    <String>['apps', 'integration_giphy'],
    <String>['index.php', 'apps', 'integration_giphy'],
  ]) {
    final prefix = <String>[...baseSegments, ...routePrefix];
    if (uri.pathSegments.length <= prefix.length) {
      continue;
    }
    var matches = true;
    for (var index = 0; index < prefix.length; index++) {
      if (uri.pathSegments[index] != prefix[index]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return true;
    }
  }
  return false;
}

bool _matchesThumbnailSignature(String contentType, Uint8List body) {
  bool startsWith(List<int> signature) {
    if (body.length < signature.length) {
      return false;
    }
    for (var index = 0; index < signature.length; index++) {
      if (body[index] != signature[index]) {
        return false;
      }
    }
    return true;
  }

  return switch (contentType) {
    'image/gif' =>
      (startsWith(ascii.encode('GIF87a')) ||
              startsWith(ascii.encode('GIF89a'))) &&
          _hasSafeGifLogicalScreen(body),
    'image/png' => startsWith(const <int>[
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ]),
    'image/jpeg' => startsWith(const <int>[0xff, 0xd8, 0xff]),
    'image/webp' =>
      body.length >= 12 &&
          startsWith(ascii.encode('RIFF')) &&
          ascii.decode(body.sublist(8, 12), allowInvalid: true) == 'WEBP',
    _ => false,
  };
}

bool _hasSafeGifLogicalScreen(Uint8List body) {
  if (body.length < 10) {
    return false;
  }
  final width = body[6] | (body[7] << 8);
  final height = body[8] | (body[9] << 8);
  if (width == 0 ||
      height == 0 ||
      width > _maximumGifLogicalDimension ||
      height > _maximumGifLogicalDimension) {
    return false;
  }
  return width <= _maximumGifLogicalPixels ~/ height;
}

double? _gifAspectRatio(Uint8List body) {
  if (!_hasSafeGifLogicalScreen(body)) {
    return null;
  }
  final width = body[6] | (body[7] << 8);
  final height = body[8] | (body[9] << 8);
  return width / height;
}

Duration _remaining(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) {
    throw TimeoutException('Giphy request deadline exceeded');
  }
  return remaining;
}

Future<void> _cancelIterator(
  StreamIterator<List<int>> iterator,
  DateTime deadline,
) async {
  try {
    final cancellation = iterator.cancel();
    final remaining = deadline.difference(DateTime.now());
    final budget =
        remaining > Duration.zero && remaining < _abortSettlementTimeout
        ? remaining
        : _abortSettlementTimeout;
    await cancellation.timeout(budget);
  } on Object {
    // Cancellation is capped by the bounded settlement window.
  }
}

const _abortSettlementTimeout = Duration(milliseconds: 100);

Future<T> _sendWithDeadline<T>(
  Future<T> send, {
  required DateTime deadline,
  required _RequestAbortSignal requestAbort,
}) async {
  final normalized = Completer<T>();
  unawaited(
    send.then<void>(
      (value) => normalized.complete(value),
      onError: (Object error, StackTrace stackTrace) {
        normalized.completeError(error, stackTrace);
      },
    ),
  );
  try {
    return await normalized.future.timeout(_remaining(deadline));
  } on TimeoutException {
    requestAbort.abortForDeadline();
    return normalized.future.timeout(_abortSettlementTimeout);
  }
}

final class _ResponseBodyReader {
  _ResponseBodyReader(Stream<List<int>> stream)
    : _iterator = StreamIterator<List<int>>(stream) {
    _startMove();
  }

  final StreamIterator<List<int>> _iterator;
  Future<bool>? _pendingMove;

  List<int> get current => _iterator.current;

  Future<bool> moveNext(DateTime deadline) async {
    final pending = _pendingMove ?? _startMove();
    final hasNext = await pending.timeout(_remaining(deadline));
    if (identical(_pendingMove, pending)) {
      _pendingMove = null;
    }
    return hasNext;
  }

  Future<bool> _startMove() {
    final pending = _iterator.moveNext();
    _pendingMove = pending;
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {},
      ),
    );
    return pending;
  }

  Future<void> cancel(DateTime deadline) {
    return _cancelIterator(_iterator, deadline);
  }
}

enum _RequestAbortCause { caller, deadline }

final class _RequestAbortSignal {
  _RequestAbortSignal({
    required DateTime deadline,
    required Future<void>? callerTrigger,
  }) {
    final remaining = deadline.difference(DateTime.now());
    _deadlineTimer = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      abortForDeadline,
    );
    if (callerTrigger != null) {
      _callerSubscription = Stream<void>.fromFuture(callerTrigger).listen(
        (_) => _abort(_RequestAbortCause.caller),
        onError: (Object error, StackTrace stackTrace) {
          _abort(_RequestAbortCause.caller);
        },
      );
    }
  }

  final Completer<void> _trigger = Completer<void>();
  late final Timer _deadlineTimer;
  StreamSubscription<void>? _callerSubscription;
  _RequestAbortCause? _cause;
  bool _disposed = false;

  Future<void> get trigger => _trigger.future;

  GiphyError get error => _cause == _RequestAbortCause.deadline
      ? GiphyError.timeout
      : GiphyError.cancelled;

  void abortForDeadline() => _abort(_RequestAbortCause.deadline);

  void _abort(_RequestAbortCause cause) {
    if (_disposed || _trigger.isCompleted) {
      return;
    }
    _cause = cause;
    _trigger.complete();
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _deadlineTimer.cancel();
    final callerSubscription = _callerSubscription;
    _callerSubscription = null;
    if (callerSubscription != null) {
      unawaited(callerSubscription.cancel());
    }
  }
}
