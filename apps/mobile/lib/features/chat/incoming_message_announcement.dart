import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/semantics.dart';

typedef IncomingMessageAnnouncement =
    Future<void> Function(String message, ui.TextDirection textDirection);

typedef IncomingMessageAnnouncementRow = ({
  int messageId,
  String actorId,
  String actorDisplayName,
  String systemMessage,
  String messageType,
  String displayText,
  bool deleted,
});

final class IncomingMessageAnnouncementController {
  IncomingMessageAnnouncementController({
    IncomingMessageAnnouncement? announce,
    this.debounce = const Duration(milliseconds: 350),
  }) : _announce = announce ?? _announceThroughSemantics;

  static const int _maximumSenderRunes = 40;
  static const int _maximumMessageRunes = 120;
  static const int _maximumAnnouncementRunes = 280;
  static const int _maximumPendingMessages = 5;

  final IncomingMessageAnnouncement _announce;
  final Duration debounce;

  int? _newestObservedMessageId;
  Timer? _timer;
  final List<_PendingIncomingMessage> _pending = [];
  String _activityLabel = '';
  ui.TextDirection _textDirection = ui.TextDirection.ltr;
  bool Function()? _canAnnounce;

  void observeAuthoritativeMerge({
    required Iterable<IncomingMessageAnnouncementRow> messages,
    required int? authoritativeMessageId,
    required String localLoginName,
    required String activityLabel,
    required ui.TextDirection textDirection,
    required bool Function() canAnnounce,
  }) {
    if (authoritativeMessageId == null || authoritativeMessageId < 1) {
      return;
    }
    final rows = messages.toList(growable: false);
    final previous = _newestObservedMessageId;
    _newestObservedMessageId =
        previous == null || authoritativeMessageId > previous
        ? authoritativeMessageId
        : previous;
    if (previous == null) {
      return;
    }
    if (!canAnnounce()) {
      cancelPending();
      return;
    }

    final incoming =
        rows
            .where(
              (row) =>
                  row.messageId > previous &&
                  row.messageId <= authoritativeMessageId,
            )
            .where(
              (row) =>
                  !row.deleted &&
                  row.actorId != localLoginName &&
                  row.systemMessage.isEmpty &&
                  row.messageType == 'comment' &&
                  row.displayText.trim().isNotEmpty,
            )
            .toList(growable: false)
          ..sort((left, right) => left.messageId.compareTo(right.messageId));
    if (incoming.isEmpty) {
      return;
    }

    for (final row in incoming) {
      if (_pending.length == _maximumPendingMessages) {
        break;
      }
      if (_pending.any((pending) => pending.messageId == row.messageId)) {
        continue;
      }
      _pending.add(
        _PendingIncomingMessage(
          messageId: row.messageId,
          sender: _boundedText(row.actorDisplayName, _maximumSenderRunes),
          text: _boundedText(row.displayText, _maximumMessageRunes),
        ),
      );
    }
    _activityLabel = _boundedText(activityLabel, _maximumSenderRunes);
    _textDirection = textDirection;
    _canAnnounce = canAnnounce;
    _timer?.cancel();
    _timer = Timer(debounce, _flush);
  }

  void reset() {
    cancelPending();
    _newestObservedMessageId = null;
  }

  void cancelPending() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }

  void dispose() => reset();

  void _flush() {
    _timer = null;
    if (_pending.isEmpty || !(_canAnnounce?.call() ?? false)) {
      _pending.clear();
      return;
    }
    final fragments = _pending
        .map((message) {
          if (message.sender.isEmpty) {
            return message.text;
          }
          return '${message.sender}: ${message.text}';
        })
        .join('. ');
    _pending.clear();
    final prefix = _activityLabel.isEmpty ? '' : '$_activityLabel. ';
    final announcement = _boundedText(
      '$prefix$fragments',
      _maximumAnnouncementRunes,
    );
    if (announcement.isNotEmpty) {
      _announce(announcement, _textDirection).ignore();
    }
  }

  static Future<void> _announceThroughSemantics(
    String message,
    ui.TextDirection textDirection,
  ) {
    final view = ui.PlatformDispatcher.instance.implicitView;
    if (view == null) {
      return Future<void>.value();
    }
    return SemanticsService.sendAnnouncement(view, message, textDirection);
  }

  static String _boundedText(String value, int maximumRunes) {
    final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    final runes = normalized.runes;
    if (runes.length <= maximumRunes) {
      return normalized;
    }
    return '${String.fromCharCodes(runes.take(maximumRunes - 1))}\u2026';
  }
}

final class _PendingIncomingMessage {
  const _PendingIncomingMessage({
    required this.messageId,
    required this.sender,
    required this.text,
  });

  final int messageId;
  final String sender;
  final String text;
}
