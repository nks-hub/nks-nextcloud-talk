import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

import 'composer_text_editing.dart';

enum GiphyAvailabilityState { available, unavailable, unknown }

final class GiphyAvailability {
  const GiphyAvailability._(this.state);

  factory GiphyAvailability.fromCapabilities(CapabilitySnapshot snapshot) {
    if (!snapshot.capabilities.containsKey('integration_giphy')) {
      return const GiphyAvailability._(GiphyAvailabilityState.unknown);
    }
    final raw = snapshot.capabilities['integration_giphy'];
    final available =
        raw is Map<String, Object?> &&
        raw['enabled'] == true &&
        raw['configured'] == true;
    return GiphyAvailability._(
      available
          ? GiphyAvailabilityState.available
          : GiphyAvailabilityState.unavailable,
    );
  }

  final GiphyAvailabilityState state;

  bool get isAvailable => state == GiphyAvailabilityState.available;
  bool get shouldProbe => state == GiphyAvailabilityState.unknown;
}

final class GiphyAuthorization {
  const GiphyAuthorization({
    required this.loginName,
    required this.appPassword,
  });

  final String loginName;
  final String appPassword;

  Map<String, String> get requestHeaders => <String, String>{
    'Accept': 'application/json',
    'OCS-APIRequest': 'true',
    'Authorization':
        'Basic ${base64Encode(utf8.encode('$loginName:$appPassword'))}',
  };

  @override
  String toString() => 'GiphyAuthorization(<redacted>)';
}

final class GiphyEntry {
  const GiphyEntry({
    required this.thumbnailUrl,
    required this.title,
    required this.subline,
    required this.resourceUrl,
  });

  final Uri thumbnailUrl;
  final String title;
  final String subline;
  final Uri resourceUrl;
}

final class GiphyPage {
  GiphyPage({required Iterable<GiphyEntry> entries, required this.cursor})
    : entries = List<GiphyEntry>.unmodifiable(entries);

  final List<GiphyEntry> entries;
  final int cursor;
}

final class GiphyThumbnail {
  GiphyThumbnail({required Uint8List body, required this.contentType})
    : body = Uint8List.fromList(body);

  final Uint8List body;
  final String contentType;
}

enum GiphyError {
  integrationUnavailable,
  cancelled,
  network,
  timeout,
  responseTooLarge,
  invalidResponse,
  rateLimited,
  unexpectedStatus,
}

final class GiphyException implements Exception {
  const GiphyException(this.error, {this.statusCode});

  final GiphyError error;
  final int? statusCode;

  @override
  String toString() => 'GiphyException(${error.name}, statusCode: $statusCode)';
}

abstract interface class GiphyRepository {
  Future<GiphyPage> trending({
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  });

  Future<GiphyPage> search({
    required String term,
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  });
}

final class HttpGiphyRepository implements GiphyRepository {
  HttpGiphyRepository({
    required this.server,
    required this.authorization,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 20),
    this.maximumResponseBytes = 2 * 1024 * 1024,
    this.maximumThumbnailBytes = 8 * 1024 * 1024,
  }) : _client = client ?? http.Client() {
    if (maximumResponseBytes < 1 || maximumThumbnailBytes < 1) {
      throw ArgumentError.value(
        maximumResponseBytes < 1 ? maximumResponseBytes : maximumThumbnailBytes,
        maximumResponseBytes < 1
            ? 'maximumResponseBytes'
            : 'maximumThumbnailBytes',
        'must be positive',
      );
    }
  }

  final ServerBase server;
  final GiphyAuthorization authorization;
  final Duration requestTimeout;
  final int maximumResponseBytes;
  final int maximumThumbnailBytes;
  final http.Client _client;
  ({int cursor, int limit, GiphyPage page})? _prefetchedTrending;
  bool _closed = false;

  @override
  Future<GiphyPage> trending({
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) {
    if (_closed || cursor < 0 || limit < 1 || limit > 50) {
      return Future<GiphyPage>.error(
        const GiphyException(GiphyError.invalidResponse),
      );
    }
    final prefetched = _prefetchedTrending;
    if (prefetched != null &&
        prefetched.cursor == cursor &&
        prefetched.limit == limit) {
      _prefetchedTrending = null;
      return Future<GiphyPage>.value(prefetched.page);
    }
    return _fetch(
      endpoint: 'gifs/trending',
      cursor: cursor,
      limit: limit,
      abortTrigger: abortTrigger,
    );
  }

  Future<void> probeAvailability({int cursor = 0, int limit = 20}) async {
    final page = await _fetch(
      endpoint: 'gifs/trending',
      cursor: cursor,
      limit: limit,
    );
    _prefetchedTrending = (cursor: cursor, limit: limit, page: page);
  }

  @override
  Future<GiphyPage> search({
    required String term,
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) {
    final normalized = term.trim();
    if (normalized.isEmpty || normalized.length > 200) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    return _fetch(
      endpoint: 'gifs/search',
      cursor: cursor,
      limit: limit,
      term: normalized,
      abortTrigger: abortTrigger,
    );
  }

  Future<GiphyThumbnail> loadThumbnail(
    GiphyEntry entry, {
    Future<void>? abortTrigger,
  }) async {
    if (_closed || !_isSafeThumbnail(server, entry.thumbnailUrl)) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final deadline = DateTime.now().add(requestTimeout);
    final requestAbort = _RequestAbortSignal(
      deadline: deadline,
      callerTrigger: abortTrigger,
    );
    _ResponseBodyReader? bodyReader;
    try {
      final request =
          http.AbortableRequest(
              'GET',
              entry.thumbnailUrl,
              abortTrigger: requestAbort.trigger,
            )
            ..headers.addAll(<String, String>{
              ...authorization.requestHeaders,
              'Accept': 'image/gif,image/webp,image/png,image/jpeg',
            })
            ..followRedirects = false
            ..maxRedirects = 0;
      final response = await _sendWithDeadline(
        _client.send(request),
        deadline: deadline,
        requestAbort: requestAbort,
      );
      bodyReader = _ResponseBodyReader(response.stream);
      if (response.statusCode != 200) {
        var discarded = 0;
        while (await bodyReader.moveNext(deadline)) {
          discarded += bodyReader.current.length;
          if (discarded > maximumThumbnailBytes) {
            break;
          }
        }
        throw switch (response.statusCode) {
          401 => const GiphyException(GiphyError.integrationUnavailable),
          429 => const GiphyException(GiphyError.rateLimited, statusCode: 429),
          _ => GiphyException(
            GiphyError.unexpectedStatus,
            statusCode: response.statusCode,
          ),
        };
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maximumThumbnailBytes) {
        throw const GiphyException(GiphyError.responseTooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      while (await bodyReader.moveNext(deadline)) {
        final chunk = bodyReader.current;
        received += chunk.length;
        if (received > maximumThumbnailBytes) {
          throw const GiphyException(GiphyError.responseTooLarge);
        }
        bytes.add(chunk);
      }
      final body = bytes.takeBytes();
      final contentType = response.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (contentType == null ||
          body.isEmpty ||
          !_matchesThumbnailSignature(contentType, body)) {
        throw const GiphyException(GiphyError.invalidResponse);
      }
      return GiphyThumbnail(body: body, contentType: contentType);
    } on GiphyException {
      rethrow;
    } on http.RequestAbortedException {
      throw GiphyException(requestAbort.error);
    } on TimeoutException {
      requestAbort.abortForDeadline();
      throw GiphyException(requestAbort.error);
    } on http.ClientException {
      throw const GiphyException(GiphyError.network);
    } finally {
      if (bodyReader != null) {
        await bodyReader.cancel(deadline);
      }
      requestAbort.dispose();
    }
  }

  Future<GiphyPage> _fetch({
    required String endpoint,
    required int cursor,
    required int limit,
    String? term,
    Future<void>? abortTrigger,
  }) async {
    if (_closed || cursor < 0 || limit < 1 || limit > 50) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final pathPrefix = server.basePath;
    final uri = server.uri.replace(
      path: '$pathPrefix/ocs/v2.php/apps/integration_giphy/api/v1/$endpoint',
      queryParameters: <String, String>{
        'term': ?term,
        'cursor': '$cursor',
        'limit': '$limit',
        'format': 'json',
      },
    );
    final deadline = DateTime.now().add(requestTimeout);
    final requestAbort = _RequestAbortSignal(
      deadline: deadline,
      callerTrigger: abortTrigger,
    );
    _ResponseBodyReader? bodyReader;
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: requestAbort.trigger)
            ..headers.addAll(authorization.requestHeaders)
            ..followRedirects = false
            ..maxRedirects = 0;
      final response = await _sendWithDeadline(
        _client.send(request),
        deadline: deadline,
        requestAbort: requestAbort,
      );
      bodyReader = _ResponseBodyReader(response.stream);
      if (response.statusCode != 200) {
        var discarded = 0;
        while (await bodyReader.moveNext(deadline)) {
          discarded += bodyReader.current.length;
          if (discarded > maximumResponseBytes) {
            break;
          }
        }
        throw switch (response.statusCode) {
          401 || 404 => const GiphyException(GiphyError.integrationUnavailable),
          429 => const GiphyException(GiphyError.rateLimited, statusCode: 429),
          _ => GiphyException(
            GiphyError.unexpectedStatus,
            statusCode: response.statusCode,
          ),
        };
      }
      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maximumResponseBytes) {
        throw const GiphyException(GiphyError.responseTooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      var received = 0;
      while (await bodyReader.moveNext(deadline)) {
        final chunk = bodyReader.current;
        received += chunk.length;
        if (received > maximumResponseBytes) {
          throw const GiphyException(GiphyError.responseTooLarge);
        }
        bytes.add(chunk);
      }
      return _decodePage(bytes.takeBytes());
    } on GiphyException {
      rethrow;
    } on http.RequestAbortedException {
      throw GiphyException(requestAbort.error);
    } on TimeoutException {
      requestAbort.abortForDeadline();
      throw GiphyException(requestAbort.error);
    } on http.ClientException {
      throw const GiphyException(GiphyError.network);
    } on FormatException {
      throw const GiphyException(GiphyError.invalidResponse);
    } finally {
      if (bodyReader != null) {
        await bodyReader.cancel(deadline);
      }
      requestAbort.dispose();
    }
  }

  GiphyPage _decodePage(Uint8List bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final root = _object(decoded);
    final ocs = _object(root['ocs']);
    final meta = _object(ocs['meta']);
    if (meta['status'] != 'ok' || meta['statuscode'] != 200) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    final data = _object(ocs['data']);
    final rawEntries = data['entries'];
    final cursor = data['cursor'];
    if (rawEntries is! List<Object?> ||
        rawEntries.length > 50 ||
        cursor is! int ||
        cursor < 0) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    return GiphyPage(entries: rawEntries.map(_decodeEntry), cursor: cursor);
  }

  GiphyEntry _decodeEntry(Object? raw) {
    final entry = _object(raw);
    final thumbnailUrl = _uri(entry['thumbnailUrl']);
    final resourceUrl = _uri(entry['resourceUrl']);
    final title = _boundedString(entry['title'], maximumLength: 4096);
    final subline = _boundedString(entry['subline'], maximumLength: 4096);
    if (!server.hasSameOrigin(thumbnailUrl) ||
        thumbnailUrl.userInfo.isNotEmpty ||
        thumbnailUrl.fragment.isNotEmpty ||
        thumbnailUrl.path.isEmpty ||
        !_isSafeGiphyResource(resourceUrl)) {
      throw const GiphyException(GiphyError.invalidResponse);
    }
    return GiphyEntry(
      thumbnailUrl: thumbnailUrl,
      title: title,
      subline: subline,
      resourceUrl: resourceUrl,
    );
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _prefetchedTrending = null;
    _client.close();
  }
}

enum GiphyLoadPhase { idle, loading, ready, error }

final class GiphyController extends ChangeNotifier {
  GiphyController({required this.repository, this.pageSize = 20});

  final GiphyRepository repository;
  final int pageSize;

  List<GiphyEntry> _entries = const <GiphyEntry>[];
  GiphyLoadPhase _phase = GiphyLoadPhase.idle;
  GiphyError? _error;
  String? _term;
  int _cursor = 0;
  int _generation = 0;
  Completer<void>? _abort;
  bool _disposed = false;

  List<GiphyEntry> get entries => _entries;
  GiphyLoadPhase get phase => _phase;
  GiphyError? get error => _error;
  String? get term => _term;
  int get cursor => _cursor;

  Future<bool> loadTrending() => _load(term: null, append: false);

  Future<bool> search(String term) {
    final normalized = term.trim();
    return normalized.isEmpty
        ? loadTrending()
        : _load(term: normalized, append: false);
  }

  Future<bool> loadMore() => _load(term: _term, append: true);

  bool insertSelection(
    TextEditingController composer,
    GiphyEntry entry, {
    int maximumCharacters = 32000,
  }) => insertComposerText(
    composer,
    entry.resourceUrl.toString(),
    mode: ComposerInsertionMode.separatedToken,
    maximumCharacters: maximumCharacters,
  );

  Future<bool> _load({required String? term, required bool append}) async {
    if (_disposed ||
        pageSize < 1 ||
        pageSize > 50 ||
        (_phase == GiphyLoadPhase.loading && append)) {
      return false;
    }
    final generation = ++_generation;
    _abort?.complete();
    final abort = _abort = Completer<void>();
    final requestedCursor = append ? _cursor : 0;
    _phase = GiphyLoadPhase.loading;
    _error = null;
    if (!append) {
      _term = term;
    }
    notifyListeners();
    try {
      final page = term == null
          ? await repository.trending(
              cursor: requestedCursor,
              limit: pageSize,
              abortTrigger: abort.future,
            )
          : await repository.search(
              term: term,
              cursor: requestedCursor,
              limit: pageSize,
              abortTrigger: abort.future,
            );
      if (_disposed || generation != _generation) {
        return false;
      }
      _entries = List<GiphyEntry>.unmodifiable(
        append ? <GiphyEntry>[..._entries, ...page.entries] : page.entries,
      );
      _cursor = page.cursor;
      _phase = GiphyLoadPhase.ready;
      notifyListeners();
      return true;
    } on GiphyException catch (error) {
      if (_disposed || generation != _generation) {
        return false;
      }
      _phase = GiphyLoadPhase.error;
      _error = error.error;
      notifyListeners();
      return false;
    } on Object {
      if (_disposed || generation != _generation) {
        return false;
      }
      _phase = GiphyLoadPhase.error;
      _error = GiphyError.network;
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    _abort?.complete();
    super.dispose();
  }
}

final class GiphyPickerLabels {
  const GiphyPickerLabels({
    required this.searchHint,
    required this.noResults,
    required this.retry,
    required this.loadMore,
  });

  final String searchHint;
  final String noResults;
  final String retry;
  final String loadMore;
}

typedef GiphyThumbnailBuilder =
    Widget Function(BuildContext context, GiphyEntry entry);

final class GiphyPicker extends StatelessWidget {
  const GiphyPicker({
    required this.controller,
    required this.labels,
    required this.thumbnailBuilder,
    required this.onSelected,
    super.key,
  });

  final GiphyController controller;
  final GiphyPickerLabels labels;
  final GiphyThumbnailBuilder thumbnailBuilder;
  final ValueChanged<GiphyEntry> onSelected;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const Key('giphy-search'),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: labels.searchHint,
                prefixIcon: const Icon(Icons.search_rounded),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: controller.search,
            ),
          ),
          Expanded(child: _buildResults(context)),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (controller.phase == GiphyLoadPhase.loading &&
        controller.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.phase == GiphyLoadPhase.error &&
        controller.entries.isEmpty) {
      return Center(
        child: FilledButton(
          onPressed: controller.term == null
              ? controller.loadTrending
              : () => controller.search(controller.term!),
          child: Text(labels.retry),
        ),
      );
    }
    if (controller.entries.isEmpty) {
      return Center(child: Text(labels.noResults));
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(8),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: controller.entries.length,
            itemBuilder: (context, index) {
              final entry = controller.entries[index];
              return Semantics(
                button: true,
                label: entry.title,
                child: InkWell(
                  onTap: () => onSelected(entry),
                  child: thumbnailBuilder(context, entry),
                ),
              );
            },
          ),
        ),
        SliverToBoxAdapter(
          child: Center(
            child: TextButton(
              onPressed: controller.phase == GiphyLoadPhase.loading
                  ? null
                  : controller.loadMore,
              child: Text(labels.loadMore),
            ),
          ),
        ),
      ],
    );
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const GiphyException(GiphyError.invalidResponse);
  }
  return value;
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

bool _isSafeGiphyResource(Uri uri) {
  final host = uri.host.toLowerCase();
  return uri.scheme == 'https' &&
      (host == 'giphy.com' || host.endsWith('.giphy.com')) &&
      uri.userInfo.isEmpty &&
      uri.fragment.isEmpty &&
      uri.pathSegments.isNotEmpty;
}

bool _isSafeThumbnail(ServerBase server, Uri uri) {
  if (!server.hasSameOrigin(uri) ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    return false;
  }
  final prefix = <String>[
    ...server.uri.pathSegments,
    'apps',
    'integration_giphy',
  ];
  if (uri.pathSegments.length <= prefix.length) {
    return false;
  }
  for (var index = 0; index < prefix.length; index++) {
    if (uri.pathSegments[index] != prefix[index]) {
      return false;
    }
  }
  return true;
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
      startsWith(ascii.encode('GIF87a')) || startsWith(ascii.encode('GIF89a')),
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
}) {
  return send.timeout(
    _remaining(deadline),
    onTimeout: () {
      requestAbort.abortForDeadline();
      return send.timeout(_abortSettlementTimeout);
    },
  );
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
