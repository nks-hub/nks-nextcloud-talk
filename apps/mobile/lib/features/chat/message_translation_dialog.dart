import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import 'chat_message_content.dart';
import 'message_translation_service.dart';

final class MessageTranslationDialog extends StatefulWidget {
  const MessageTranslationDialog({
    super.key,
    required this.account,
    required this.roomToken,
    required this.message,
    required this.service,
  });

  final StoredAccount account;
  final String roomToken;
  final ChatMessage message;
  final MessageTranslationService service;

  @override
  State<MessageTranslationDialog> createState() =>
      _MessageTranslationDialogState();
}

final class _MessageTranslationDialogState
    extends State<MessageTranslationDialog> {
  List<TranslationLanguagePair> _pairs = const [];
  TranslationLanguagePair? _selectedPair;
  String? _selectedSource;
  String? _selectedTarget;
  String? _translatedText;
  MessageTranslationError? _error;
  bool _languageDetection = false;
  bool _loadingLanguages = true;
  bool _translating = false;
  int _generation = 0;
  Completer<void>? _abort;
  String? _preferredLanguage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_preferredLanguage == null) {
      _preferredLanguage = Localizations.localeOf(context).languageCode;
      unawaited(_loadLanguages());
    }
  }

  @override
  void dispose() {
    _generation++;
    _cancel();
    super.dispose();
  }

  Future<void> _loadLanguages() async {
    final operation = _begin();
    setState(() {
      _loadingLanguages = true;
      _error = null;
      _translatedText = null;
    });
    try {
      final response = await widget.service.languages(
        accountId: widget.account.id,
        roomToken: widget.roomToken,
        abortTrigger: operation.abort.future,
      );
      if (!_owns(operation.generation)) {
        return;
      }
      final pairs = response.languages;
      if (pairs.isEmpty) {
        setState(() {
          _loadingLanguages = false;
          _error = MessageTranslationError.unsupported;
        });
        return;
      }
      final preferred = _preferredLanguage;
      final target = pairs
          .where((pair) => pair.to == preferred)
          .firstOrNull
          ?.to;
      final selectedTarget = target ?? pairs.first.to;
      final selectedSource = response.languageDetection
          ? null
          : pairs.firstWhere((pair) => pair.to == selectedTarget).from;
      final selectedPair = pairs
          .where(
            (pair) =>
                pair.to == selectedTarget &&
                (selectedSource == null || pair.from == selectedSource),
          )
          .firstOrNull;
      setState(() {
        _pairs = pairs;
        _languageDetection = response.languageDetection;
        _selectedSource = selectedSource;
        _selectedTarget = selectedTarget;
        _selectedPair = selectedPair;
        _loadingLanguages = false;
      });
    } on MessageTranslationException catch (failure) {
      if (_owns(operation.generation) &&
          failure.code != MessageTranslationError.cancelled) {
        setState(() {
          _loadingLanguages = false;
          _error = failure.code;
        });
      }
    }
  }

  Future<void> _translate() async {
    final target = _selectedTarget;
    if (target == null || _translating) {
      return;
    }
    final operation = _begin();
    setState(() {
      _translating = true;
      _error = null;
      _translatedText = null;
    });
    try {
      final response = await widget.service.translate(
        accountId: widget.account.id,
        roomToken: widget.roomToken,
        text: widget.message.message,
        fromLanguage: _selectedSource,
        toLanguage: target,
        abortTrigger: operation.abort.future,
      );
      if (!_owns(operation.generation)) {
        return;
      }
      setState(() {
        _translatedText = response.text;
        _translating = false;
      });
    } on MessageTranslationException catch (failure) {
      if (_owns(operation.generation) &&
          failure.code != MessageTranslationError.cancelled) {
        setState(() {
          _translating = false;
          _error = failure.code;
        });
      }
    }
  }

  _TranslationOperation _begin() {
    _cancel();
    final abort = Completer<void>();
    _abort = abort;
    return _TranslationOperation(++_generation, abort);
  }

  void _cancel() {
    final abort = _abort;
    _abort = null;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
  }

  bool _owns(int generation) => mounted && generation == _generation;

  List<_LanguageOption> get _sourceOptions {
    final options = <String, _LanguageOption>{};
    for (final pair in _pairs) {
      if (_selectedTarget == null || pair.to == _selectedTarget) {
        options[pair.from] = _LanguageOption(pair.from, pair.fromLabel);
      }
    }
    return options.values.toList(growable: false)
      ..sort((left, right) => left.label.compareTo(right.label));
  }

  List<_LanguageOption> get _targetOptions {
    final options = <String, _LanguageOption>{};
    for (final pair in _pairs) {
      if (_selectedSource == null || pair.from == _selectedSource) {
        options[pair.to] = _LanguageOption(pair.to, pair.toLabel);
      }
    }
    return options.values.toList(growable: false)
      ..sort((left, right) => left.label.compareTo(right.label));
  }

  TranslationLanguagePair? _findPair(String? source, String? target) {
    if (target == null) {
      return null;
    }
    return _pairs
        .where(
          (pair) =>
              pair.to == target && (source == null || pair.from == source),
        )
        .firstOrNull;
  }

  void _changeSource(String? source) {
    final targets = _pairs.where((pair) => pair.from == source).toList();
    final target = source == null
        ? _selectedTarget
        : targets.any((pair) => pair.to == _selectedTarget)
        ? _selectedTarget
        : targets.firstOrNull?.to;
    setState(() {
      _selectedSource = source;
      _selectedTarget = target;
      _selectedPair = _findPair(source, target);
      _translatedText = null;
      _error = null;
    });
  }

  void _changeTarget(String? target) {
    if (target == null) {
      return;
    }
    final sources = _pairs.where((pair) => pair.to == target).toList();
    final source = _languageDetection
        ? _selectedSource
        : sources.any((pair) => pair.from == _selectedSource)
        ? _selectedSource
        : sources.firstOrNull?.from;
    setState(() {
      _selectedSource = source;
      _selectedTarget = target;
      _selectedPair = _findPair(source, target);
      _translatedText = null;
      _error = null;
    });
  }

  Future<void> _copyTranslation() async {
    final text = _translatedText;
    if (text == null) {
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException {
      if (mounted) {
        _showCopyResult(
          AppLocalizations.of(context).translationCopyFailed,
          const Key('translation-copy-failed'),
        );
      }
      return;
    }
    if (!mounted) {
      return;
    }
    _showCopyResult(
      AppLocalizations.of(context).translationCopied,
      const Key('translation-copied'),
    );
  }

  void _showCopyResult(String message, Key key) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: key, content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      key: const Key('message-translation-dialog'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.translationTitle,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: _loadingLanguages
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: CircularProgressIndicator(
                              key: Key('translation-languages-loading'),
                            ),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _selectors(strings),
                            const SizedBox(height: 16),
                            OutlinedButton(
                              key: const Key('translation-submit'),
                              onPressed: _selectedPair == null || _translating
                                  ? null
                                  : _translate,
                              child: _translating
                                  ? const SizedBox.square(
                                      dimension: 24,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(strings.translationAction),
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                _errorMessage(strings, _error!),
                                key: const Key('translation-error'),
                                style: TextStyle(color: colors.error),
                              ),
                              if (_pairs.isEmpty)
                                TextButton(
                                  onPressed: _loadLanguages,
                                  child: Text(strings.retry),
                                ),
                            ],
                            const SizedBox(height: 16),
                            _messagePanel(
                              context,
                              text: widget.message.message,
                              translated: false,
                            ),
                            if (_translatedText != null) ...[
                              const SizedBox(height: 16),
                              _messagePanel(
                                context,
                                text: _translatedText!,
                                translated: true,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                strings.translationAiNotice,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  key: const Key('translation-copy'),
                                  onPressed: _copyTranslation,
                                  icon: const Icon(Icons.copy_outlined),
                                  label: Text(strings.translationCopy),
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectors(AppLocalizations strings) {
    final sources = _sourceOptions;
    final targets = _targetOptions;
    return Column(
      children: [
        KeyedSubtree(
          key: const Key('translation-source'),
          child: DropdownButtonFormField<String?>(
            key: ValueKey((_selectedSource, _selectedTarget)),
            initialValue: _selectedSource,
            isExpanded: true,
            decoration: InputDecoration(labelText: strings.translationFrom),
            items: [
              if (_languageDetection)
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(strings.translationDetectLanguage),
                ),
              for (final source in sources)
                DropdownMenuItem<String?>(
                  value: source.id,
                  child: Text(source.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _translating ? null : _changeSource,
          ),
        ),
        const SizedBox(height: 12),
        KeyedSubtree(
          key: const Key('translation-target'),
          child: DropdownButtonFormField<String>(
            key: ValueKey((_selectedSource, _selectedTarget)),
            initialValue: _selectedTarget,
            isExpanded: true,
            decoration: InputDecoration(labelText: strings.translationTo),
            items: [
              for (final target in targets)
                DropdownMenuItem<String>(
                  value: target.id,
                  child: Text(target.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _translating ? null : _changeTarget,
          ),
        ),
      ],
    );
  }

  Widget _messagePanel(
    BuildContext context, {
    required String text,
    required bool translated,
  }) {
    final colors = Theme.of(context).colorScheme;
    final document = renderRichChatMessage(
      message: text,
      markdownEnabled: widget.message.markdown == true,
      parameters: widget.message.messageParameters,
      server: ServerBase.parse(widget.account.serverUrl),
    );
    return DecoratedBox(
      key: Key(translated ? 'translation-result' : 'translation-source-text'),
      decoration: BoxDecoration(
        border: Border.all(
          color: translated ? colors.primary : colors.outline,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: RichChatDocumentContent(
          document: document,
          foregroundColor: colors.onSurface,
        ),
      ),
    );
  }
}

final class _TranslationOperation {
  const _TranslationOperation(this.generation, this.abort);

  final int generation;
  final Completer<void> abort;
}

final class _LanguageOption {
  const _LanguageOption(this.id, this.label);

  final String id;
  final String label;
}

String _errorMessage(AppLocalizations strings, MessageTranslationError error) =>
    switch (error) {
      MessageTranslationError.accountMissing ||
      MessageTranslationError.conversationMissing =>
        strings.jumpToMessageConversationMissing,
      MessageTranslationError.credentialMissing ||
      MessageTranslationError.reauthenticationRequired =>
        strings.syncCredentialMissing,
      MessageTranslationError.unsupported => strings.translationUnavailable,
      MessageTranslationError.invalidInput => strings.translationInvalidInput,
      MessageTranslationError.rateLimited => strings.syncRateLimited,
      MessageTranslationError.serviceUnavailable ||
      MessageTranslationError.network => strings.chatUnavailable,
      MessageTranslationError.invalidResponse =>
        strings.translationInvalidResponse,
      MessageTranslationError.cancelled => strings.chatUnavailable,
    };
