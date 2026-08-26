// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import 'deep_link_bridge.dart';

/// An incoming Talk room link resolved to a known, locally signed-in
/// account.
///
/// Resolution never guesses: [accountId] only ever refers to an account
/// whose stored server URL shares an origin with the link that produced it.
final class ResolvedDeepLink {
  const ResolvedDeepLink({required this.accountId, required this.token});

  final String accountId;
  final ConversationToken token;
}

/// Matches an incoming `https://<server>/(index.php/)call/<token>` link to
/// the one locally stored account whose server shares the link's origin.
///
/// A link that matches no known account resolves to `null` rather than
/// opening a best guess.
final class DeepLinkResolver {
  const DeepLinkResolver(this._accounts);

  final AccountRepository _accounts;

  static final RegExp _callPathPattern = RegExp(
    r'^/(?:index\.php/)?call/([^/]+)/?$',
  );

  Future<ResolvedDeepLink?> resolve(Uri uri) async {
    final accounts = await _accounts.watchAccounts().first;
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
        return ResolvedDeepLink(
          accountId: account.id,
          token: ConversationToken.parse(rawToken, path: r'$.roomToken'),
        );
      } on TalkProtocolException {
        continue;
      }
    }
    return null;
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
