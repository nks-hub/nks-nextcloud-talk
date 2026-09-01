import 'dart:async';

import 'package:talk_protocol/talk_protocol.dart';

import 'client_push_session.dart';

// ignore_for_file: prefer_initializing_formals

/// Keeps one Client Push socket per account and turns every notification the
/// server pushes into a wake-up.
///
/// This is Nextcloud's own live channel, so it needs nothing beyond the server
/// the account already talks to, and it reaches every platform the app runs
/// on. It is an accelerator, never the source of truth: a wake-up only tells
/// the caller to sync, and the sync decides what actually changed.
final class ClientPushCoordinator {
  ClientPushCoordinator({
    required Future<ClientPushEndpoints?> Function(
      String accountId,
      Future<void> cancellation,
    )
    resolve,
    required Future<String> Function(
      String accountId,
      ClientPushEndpoints endpoints,
      Future<void> cancellation,
    )
    fetchToken,
    required ClientPushConnector connector,
    required void Function(String accountId) onWakeUp,
    Duration firstRetry = const Duration(seconds: 2),
    Duration maximumRetry = const Duration(minutes: 5),
    Future<void> Function(Duration)? delay,
  }) : _resolve = resolve,
       _fetchToken = fetchToken,
       _connector = connector,
       _onWakeUp = onWakeUp,
       _firstRetry = firstRetry,
       _maximumRetry = maximumRetry,
       _delay = delay ?? _sleep;

  static Future<void> _sleep(Duration duration) =>
      Future<void>.delayed(duration);

  final Future<ClientPushEndpoints?> Function(
    String accountId,
    Future<void> cancellation,
  )
  _resolve;
  final Future<String> Function(
    String accountId,
    ClientPushEndpoints endpoints,
    Future<void> cancellation,
  )
  _fetchToken;
  final ClientPushConnector _connector;
  final void Function(String accountId) _onWakeUp;
  final Duration _firstRetry;
  final Duration _maximumRetry;
  final Future<void> Function(Duration) _delay;

  final Map<String, _AccountChannel> _channels = <String, _AccountChannel>{};

  /// Starts, or keeps, the channel for [accountId].
  void follow(String accountId) {
    if (_channels.containsKey(accountId)) {
      return;
    }
    final channel = _AccountChannel();
    _channels[accountId] = channel;
    channel.runner = _run(accountId, channel);
  }

  /// Drops the channel for [accountId]; a removed account must not keep a
  /// socket open against a server it no longer has credentials for.
  Future<void> unfollow(String accountId) async {
    final channel = _channels.remove(accountId);
    await channel?.stop();
  }

  Future<void> dispose() async {
    final channels = _channels.values.toList(growable: false);
    _channels.clear();
    await Future.wait(channels.map((channel) => channel.stop()));
  }

  Future<void> _run(String accountId, _AccountChannel channel) async {
    var backoff = _firstRetry;
    while (!channel.stopped) {
      try {
        final endpoints = await _resolve(accountId, channel.cancellation);
        if (endpoints == null || !endpoints.carriesNotifications) {
          // The server offers no live channel. Polling stays in charge, and
          // retrying a capability that will not appear on its own is waste.
          return;
        }
        final token = await _fetchToken(
          accountId,
          endpoints,
          channel.cancellation,
        );
        final session = await ClientPushSession.open(
          connector: _connector,
          endpoints: endpoints,
          preAuthToken: token,
          cancellation: channel.cancellation,
        );
        channel.session = session;
        if (channel.stopped) {
          await session.close();
          return;
        }
        // A reconnect can only have happened because the socket was down, and
        // anything missed while it was down is caught by syncing right away.
        _onWakeUp(accountId);
        backoff = _firstRetry;
        final events = StreamIterator<ClientPushEvent>(session.events);
        try {
          while (!channel.stopped) {
            final hasEvent = await Future.any<bool>([
              events.moveNext(),
              channel.cancellation.then((_) => false),
            ]);
            if (!hasEvent || channel.stopped) {
              break;
            }
            if (events.current == ClientPushEvent.notification) {
              _onWakeUp(accountId);
            }
          }
        } finally {
          await events.cancel();
        }
      } on Object {
        // Transport, token and temporary local-credential failures all become
        // recoverable when the device or network state changes.
      }
      channel.session = null;
      if (channel.stopped) {
        return;
      }
      await Future.any<void>([_delay(backoff), channel.cancellation]);
      if (channel.stopped) {
        return;
      }
      final doubled = backoff * 2;
      backoff = doubled > _maximumRetry ? _maximumRetry : doubled;
    }
  }
}

final class _AccountChannel {
  final _cancellation = Completer<void>();
  Future<void>? runner;
  ClientPushSession? session;

  bool get stopped => _cancellation.isCompleted;
  Future<void> get cancellation => _cancellation.future;

  Future<void> stop() async {
    if (!_cancellation.isCompleted) {
      _cancellation.complete();
    }
    final open = session;
    session = null;
    await open?.close();
    await runner;
  }
}
