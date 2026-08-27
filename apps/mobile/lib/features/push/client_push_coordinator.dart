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
    required Future<ClientPushEndpoints?> Function(String accountId) resolve,
    required Future<String> Function(String accountId, ClientPushEndpoints)
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

  final Future<ClientPushEndpoints?> Function(String accountId) _resolve;
  final Future<String> Function(String accountId, ClientPushEndpoints)
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
    unawaited(_run(accountId, channel));
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
    for (final channel in channels) {
      await channel.stop();
    }
  }

  Future<void> _run(String accountId, _AccountChannel channel) async {
    var backoff = _firstRetry;
    while (!channel.stopped) {
      try {
        final endpoints = await _resolve(accountId);
        if (endpoints == null || !endpoints.carriesNotifications) {
          // The server offers no live channel. Polling stays in charge, and
          // retrying a capability that will not appear on its own is waste.
          return;
        }
        final token = await _fetchToken(accountId, endpoints);
        final session = await ClientPushSession.open(
          connector: _connector,
          endpoints: endpoints,
          preAuthToken: token,
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
        await for (final event in session.events) {
          if (event == ClientPushEvent.notification) {
            _onWakeUp(accountId);
          }
        }
      } on Object {
        // Every failure here is a transport or an expired token; both are
        // answered by trying again later rather than by giving up.
      }
      channel.session = null;
      if (channel.stopped) {
        return;
      }
      await _delay(backoff);
      final doubled = backoff * 2;
      backoff = doubled > _maximumRetry ? _maximumRetry : doubled;
    }
  }
}

final class _AccountChannel {
  bool stopped = false;
  ClientPushSession? session;

  Future<void> stop() async {
    stopped = true;
    final open = session;
    session = null;
    await open?.close();
  }
}
