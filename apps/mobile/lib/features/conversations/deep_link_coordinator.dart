// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart' show StoredAccount;
import 'deep_link_bridge.dart';

/// The signed-in accounts eligible to open this link. A choice is required
/// when more than one eligible account knows the room, or none knows it.
final class ResolvedDeepLink {
  const ResolvedDeepLink({
    required this.accounts,
    required this.token,
    this.messageId,
    this.threadId,
  });

  final List<StoredAccount> accounts;
  String? get accountId => accounts.length == 1 ? accounts.single.id : null;
  final ConversationToken token;
  final int? messageId;
  final int? threadId;
}

final class DeepLinkResolver {
  const DeepLinkResolver(this._accounts);

  final AccountRepository _accounts;

  static final RegExp _callPathPattern = RegExp(
    r'^/(?:index\.php/)?call/([^/]+)/?$',
  );

  Future<ResolvedDeepLink?> resolve(Uri uri) async {
    if (uri.userInfo.isNotEmpty) return null;
    final accounts = await _accounts.listAccounts();
    final candidates = <StoredAccount>[];
    ConversationToken? token;
    for (final account in accounts) {
      final ServerBase server;
      try {
        server = ServerBase.parse(account.serverUrl);
      } on TalkProtocolException {
        continue;
      }
      if (!server.hasSameOrigin(uri) || !uri.path.startsWith(server.basePath)) {
        continue;
      }
      final match = _callPathPattern.firstMatch(
        uri.path.substring(server.basePath.length),
      );
      final rawToken = match?.group(1);
      if (rawToken == null) {
        continue;
      }
      try {
        token = ConversationToken.parse(rawToken, path: r'$.roomToken');
        candidates.add(account);
      } on TalkProtocolException {
        continue;
      }
    }
    if (token == null) return null;
    final rawThread = uri.queryParametersAll['threadId'];
    final thread = rawThread?.length == 1
        ? _positiveId(rawThread!.single)
        : null;
    if (rawThread != null && thread == null) return null;
    final message = uri.fragment.startsWith('message_')
        ? _positiveId(uri.fragment.substring('message_'.length))
        : null;
    if (uri.fragment.startsWith('message_') && message == null) return null;

    final known = <StoredAccount>[];
    if (candidates.length > 1) {
      for (final account in candidates) {
        if (await _accounts.getConversation(
              accountId: account.id,
              token: token.value,
            ) !=
            null) {
          known.add(account);
        }
      }
    }
    return ResolvedDeepLink(
      accounts: List.unmodifiable(known.isEmpty ? candidates : known),
      token: token,
      messageId: message,
      threadId: thread,
    );
  }

  static int? _positiveId(String raw) {
    if (!RegExp(r'^\d+$').hasMatch(raw)) return null;
    final id = int.tryParse(raw);
    return id != null && id > 0 ? id : null;
  }
}

/// Queues resolved deep links until the conversation shell is ready to open
/// them, mirroring how `AndroidPushCoordinator` queues notification opens.
final class DeepLinkCoordinator {
  DeepLinkCoordinator({
    required DeepLinkPlatform platform,
    required DeepLinkResolver Function() resolver,
  }) : _platform = platform,
       _resolver = resolver {
    _subscription = _platform.linkOpened.listen((uri) {
      unawaited(_accept(uri));
    });
  }

  final DeepLinkPlatform _platform;
  final DeepLinkResolver Function() _resolver;
  final ListQueue<ResolvedDeepLink> _pending = ListQueue();
  final StreamController<void> _availableController =
      StreamController<void>.broadcast();
  StreamSubscription<Uri>? _subscription;
  Future<void>? _startFuture;

  /// Fires whenever a newly resolved link is ready to be taken.
  Stream<void> get linkAvailable => _availableController.stream;

  ResolvedDeepLink? takeNext() =>
      _pending.isEmpty ? null : _pending.removeFirst();

  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    final Uri? launchLink;
    try {
      launchLink = await _platform.getLaunchLink();
    } on MissingPluginException {
      return;
    }
    if (launchLink != null) {
      await _accept(launchLink);
    }
  }

  Future<void> _accept(Uri uri) async {
    final resolved = await _resolver().resolve(uri);
    if (resolved == null) {
      return;
    }
    _pending.add(resolved);
    _availableController.add(null);
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _availableController.close();
  }
}
