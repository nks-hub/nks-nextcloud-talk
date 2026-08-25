import 'dart:async';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../../network/nextcloud_api.dart';

/// The token that must precede a mention query in the composer text.
const String mentionTrigger = '@';

/// A candidate mention being typed at [start] (the `@` offset) with the
/// filter text collected so far in [query]. [end] is the caret offset right
/// after the query, i.e. where an inserted mention should splice back in.
@immutable
final class MentionQueryMatch {
  const MentionQueryMatch({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MentionQueryMatch &&
          other.start == start &&
          other.end == end &&
          other.query == query);

  @override
  int get hashCode => Object.hash(start, end, query);
}

/// Finds the `@query` token the caret currently sits inside, if any.
///
/// The `@` must start the message or follow whitespace, and the query itself
/// may not contain whitespace, so a plain "user@host" or a mention the caret
/// has already left never triggers suggestions.
MentionQueryMatch? extractMentionQuery(String text, int caret) {
  if (caret < 0 || caret > text.length) {
    return null;
  }
  var index = caret;
  while (index > 0) {
    final char = text[index - 1];
    if (char == mentionTrigger) {
      final precededByBoundary =
          index == 1 || RegExp(r'\s').hasMatch(text[index - 2]);
      if (!precededByBoundary) {
        return null;
      }
      final query = text.substring(index, caret);
      if (query.length > 4096) {
        return null;
      }
      return MentionQueryMatch(start: index - 1, end: caret, query: query);
    }
    if (RegExp(r'\s').hasMatch(char)) {
      return null;
    }
    index--;
  }
  return null;
}

/// The exact text Nextcloud Talk expects for a mention: the `mentionId` after
/// `@`, quoted whenever it contains a space or a slash (guest ids look like
/// `guest/<hash>`), matching the server's own mention parser.
String mentionSuggestionMarkup(RichChatMentionSuggestion suggestion) {
  final id = suggestion.mentionId;
  final needsQuoting = id.contains(' ') || id.contains('/');
  return needsQuoting ? '$mentionTrigger"$id"' : '$mentionTrigger$id';
}

/// Replaces the mention token the caret is currently inside with the chosen
/// suggestion's markup, followed by a trailing space, and moves the caret
/// past it. A no-op if the composer text moved on since the match was found.
bool insertMentionSuggestion(
  TextEditingController controller,
  RichChatMentionSuggestion suggestion,
) {
  final match = extractMentionQuery(
    controller.value.text,
    controller.value.selection.baseOffset,
  );
  if (match == null) {
    return false;
  }
  final insertion = '${mentionSuggestionMarkup(suggestion)} ';
  final text = controller.value.text.replaceRange(
    match.start,
    match.end,
    insertion,
  );
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: match.start + insertion.length),
  );
  return true;
}

enum MentionSuggestionError { unsupported, network, invalidResponse }

final class MentionSuggestionException implements Exception {
  const MentionSuggestionException(this.error);

  final MentionSuggestionError error;

  @override
  String toString() => 'MentionSuggestionException(${error.name})';
}

/// Account- and room-bound source of `@`-mention suggestions.
abstract interface class MentionSuggestionSource {
  Future<List<RichChatMentionSuggestion>> search({
    required String query,
    Future<void>? abortTrigger,
  });
}

final class HttpMentionSuggestionSource implements MentionSuggestionSource {
  HttpMentionSuggestionSource({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required this.profile,
    required this.loginName,
    required this.appPassword,
    required this.api,
    this.limit = 20,
    Uuid? uuid,
  }) : _uuid = uuid ?? const Uuid();

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final RichChatCapabilityProfile profile;
  final String loginName;
  final String appPassword;
  final HttpNextcloudApi api;
  final int limit;
  final Uuid _uuid;

  @override
  Future<List<RichChatMentionSuggestion>> search({
    required String query,
    Future<void>? abortTrigger,
  }) async {
    final RichChatRequest request;
    try {
      request = RichChatRequest.mentions(
        accountId: accountId,
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: server,
        roomToken: roomToken,
        profile: profile,
        search: query,
        limit: limit,
        includeStatus: true,
      );
    } on TalkProtocolException {
      throw const MentionSuggestionException(
        MentionSuggestionError.unsupported,
      );
    }
    final RichChatResponse response;
    try {
      response = await api.getMentionSuggestions(
        request: request,
        loginName: loginName,
        appPassword: appPassword,
        abortTrigger: abortTrigger,
      );
    } on NextcloudApiException {
      throw const MentionSuggestionException(MentionSuggestionError.network);
    } on TalkProtocolException {
      throw const MentionSuggestionException(
        MentionSuggestionError.invalidResponse,
      );
    }
    if (response.classification != RichChatResponseClassification.success) {
      throw const MentionSuggestionException(
        MentionSuggestionError.invalidResponse,
      );
    }
    return response.mentions;
  }
}

enum MentionSuggestionPhase { idle, loading, ready, error }

/// Debounces typed queries and suppresses results from a stale search,
/// mirroring the composer's Giphy search controller but for mentions.
final class MentionSuggestionController extends ChangeNotifier {
  MentionSuggestionController({
    required this.source,
    this.debounce = const Duration(milliseconds: 250),
  });

  final MentionSuggestionSource source;
  final Duration debounce;

  MentionSuggestionPhase _phase = MentionSuggestionPhase.idle;
  List<RichChatMentionSuggestion> _suggestions = const <RichChatMentionSuggestion>[];
  MentionSuggestionError? _error;
  int _generation = 0;
  Timer? _debounceTimer;
  Completer<void>? _abort;
  bool _disposed = false;

  MentionSuggestionPhase get phase => _phase;
  List<RichChatMentionSuggestion> get suggestions => _suggestions;
  MentionSuggestionError? get error => _error;

  void updateQuery(String query) {
    if (_disposed) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(_search(query)));
  }

  void clear() {
    if (_disposed) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _abort?.complete();
    _abort = null;
    _generation++;
    if (_phase == MentionSuggestionPhase.idle && _suggestions.isEmpty) {
      return;
    }
    _phase = MentionSuggestionPhase.idle;
    _suggestions = const <RichChatMentionSuggestion>[];
    _error = null;
    notifyListeners();
  }

  Future<void> _search(String query) async {
    if (_disposed) {
      return;
    }
    final generation = ++_generation;
    _abort?.complete();
    final abort = _abort = Completer<void>();
    _phase = MentionSuggestionPhase.loading;
    notifyListeners();
    try {
      final results = await source.search(
        query: query,
        abortTrigger: abort.future,
      );
      if (_disposed || generation != _generation) {
        return;
      }
      _suggestions = List<RichChatMentionSuggestion>.unmodifiable(results);
      _phase = MentionSuggestionPhase.ready;
      _error = null;
      notifyListeners();
    } on MentionSuggestionException catch (error) {
      if (_disposed || generation != _generation) {
        return;
      }
      _suggestions = const <RichChatMentionSuggestion>[];
      _phase = MentionSuggestionPhase.error;
      _error = error.error;
      notifyListeners();
    } on Object {
      if (_disposed || generation != _generation) {
        return;
      }
      _suggestions = const <RichChatMentionSuggestion>[];
      _phase = MentionSuggestionPhase.error;
      _error = MentionSuggestionError.network;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    _debounceTimer?.cancel();
    _abort?.complete();
    super.dispose();
  }
}

final class MentionSuggestionsLabels {
  const MentionSuggestionsLabels({required this.noResults, required this.error});

  final String noResults;
  final String error;
}

/// Shows `@`-mention suggestions above the composer text field while the
/// caret sits inside a mention token, and splices the chosen suggestion back
/// into [controller] when tapped. Renders nothing when there is no active
/// mention, no [source] (feature unavailable for this room), or the composer
/// is disabled, so it never covers the text being typed.
final class MentionSuggestionsBar extends StatefulWidget {
  const MentionSuggestionsBar({
    required this.controller,
    required this.source,
    required this.enabled,
    required this.labels,
    super.key,
  });

  final TextEditingController controller;
  final MentionSuggestionSource? source;
  final bool enabled;
  final MentionSuggestionsLabels labels;

  @override
  State<MentionSuggestionsBar> createState() => _MentionSuggestionsBarState();
}

final class _MentionSuggestionsBarState extends State<MentionSuggestionsBar> {
  MentionSuggestionController? _suggestionController;
  bool _active = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleComposerChanged);
    _rebuildSuggestionController();
  }

  @override
  void didUpdateWidget(covariant MentionSuggestionsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleComposerChanged);
      widget.controller.addListener(_handleComposerChanged);
    }
    if (!identical(oldWidget.source, widget.source)) {
      _rebuildSuggestionController();
    }
    if (!widget.enabled) {
      _deactivate();
    }
  }

  void _rebuildSuggestionController() {
    _suggestionController?.dispose();
    final source = widget.source;
    _suggestionController = source == null
        ? null
        : MentionSuggestionController(source: source);
    _deactivate();
  }

  void _handleComposerChanged() {
    final controller = _suggestionController;
    if (!widget.enabled || controller == null) {
      _deactivate();
      return;
    }
    final selection = widget.controller.value.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _deactivate();
      return;
    }
    final match = extractMentionQuery(
      widget.controller.value.text,
      selection.baseOffset,
    );
    if (match == null) {
      _deactivate();
      return;
    }
    if (!_active) {
      setState(() => _active = true);
    }
    controller.updateQuery(match.query);
  }

  void _deactivate() {
    _suggestionController?.clear();
    if (_active) {
      setState(() => _active = false);
    }
  }

  void _select(RichChatMentionSuggestion suggestion) {
    insertMentionSuggestion(widget.controller, suggestion);
    _deactivate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleComposerChanged);
    _suggestionController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _suggestionController;
    if (!_active || controller == null) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _MentionSuggestionsPanel(
        phase: controller.phase,
        suggestions: controller.suggestions,
        error: controller.error,
        labels: widget.labels,
        onSelected: _select,
      ),
    );
  }
}

final class _MentionSuggestionsPanel extends StatelessWidget {
  const _MentionSuggestionsPanel({
    required this.phase,
    required this.suggestions,
    required this.error,
    required this.labels,
    required this.onSelected,
  });

  final MentionSuggestionPhase phase;
  final List<RichChatMentionSuggestion> suggestions;
  final MentionSuggestionError? error;
  final MentionSuggestionsLabels labels;
  final ValueChanged<RichChatMentionSuggestion> onSelected;

  @override
  Widget build(BuildContext context) {
    if (phase == MentionSuggestionPhase.error) {
      return _message(context, labels.error, Icons.error_outline_rounded);
    }
    if (phase == MentionSuggestionPhase.ready && suggestions.isEmpty) {
      return _message(context, labels.noResults, Icons.alternate_email_rounded);
    }
    if (suggestions.isEmpty) {
      // Idle or still debouncing: nothing to show yet, and never an
      // indeterminate spinner here, since a stalled network call must not
      // keep this row animating forever.
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 176),
        child: ListView.builder(
          key: const Key('mention-suggestions-list'),
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: suggestions.length,
          itemBuilder: (context, index) {
            final suggestion = suggestions[index];
            return ListTile(
              key: Key('mention-suggestion-${suggestion.mentionId}'),
              dense: true,
              leading: const Icon(Icons.alternate_email_rounded),
              title: Text(suggestion.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: suggestion.details == null
                  ? null
                  : Text(
                      suggestion.details!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              onTap: () => onSelected(suggestion),
            );
          },
        ),
      ),
    );
  }

  Widget _message(BuildContext context, String text, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
