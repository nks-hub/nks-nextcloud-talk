import 'dart:async';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../l10n/generated/app_localizations.dart';
import 'new_conversation_service.dart';

part 'conversation_creation_summary.dart';

final class ConversationCreationDialog extends StatefulWidget {
  const ConversationCreationDialog({
    super.key,
    required this.service,
    required this.accountId,
    required this.initialType,
    required this.isCurrent,
    required this.abortTrigger,
    this.recipient,
  });

  final NewConversationService service;
  final String accountId;
  final StandaloneConversationType initialType;
  final bool Function() isCurrent;
  final Future<void> abortTrigger;
  final ConversationRecipient? recipient;

  @override
  State<ConversationCreationDialog> createState() =>
      _ConversationCreationDialogState();
}

final class _ConversationCreationDialogState
    extends State<ConversationCreationDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  late final _name = TextEditingController(text: widget.recipient?.label ?? '');
  final _abort = Completer<void>();
  ConversationCreationOptions? _options;
  NewConversationException? _error;
  var _loading = true;
  var _submitting = false;
  var _invalidated = false;
  var _uncertain = false;
  var _preset = 'default';
  final _userChoices = <String, int>{};

  bool get _current => mounted && !_invalidated && widget.isCurrent();
  AppLocalizations get _strings => AppLocalizations.of(context);
  Map<String, int> get _choices => {
    if (_preset == 'default')
      'roomType': widget.initialType == StandaloneConversationType.public
          ? 3
          : 2,
    ..._userChoices,
  };
  Map<String, int> get _parameters =>
      _options!.effectiveParameters(_preset, _choices);

  @override
  void initState() {
    super.initState();
    widget.abortTrigger.then((_) {
      if (!mounted) return;
      if (!_abort.isCompleted) _abort.complete();
      _password.clear();
      setState(() {
        _invalidated = true;
        _submitting = false;
        _loading = false;
      });
    });
    _load();
  }

  @override
  void dispose() {
    if (!_abort.isCompleted) _abort.complete();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final options = await widget.service.prepareCreation(
        accountId: widget.accountId,
        abortTrigger: _abort.future,
        isCurrent: () => _current,
      );
      if (!_current) return;
      setState(() {
        _options = options;
        _preset = 'default';
        _userChoices.clear();
      });
    } on NewConversationException catch (error) {
      if (_current) setState(() => _error = error);
    } finally {
      if (_current) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (!_current ||
        _submitting ||
        _uncertain ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await widget.service.createPreparedConversation(
        options: _options!,
        roomName: _name.text.trim(),
        presetIdentifier: _options!.catalog == null ? null : _preset,
        userParameters: _choices,
        password: _parameters['roomType'] == 3 ? _password.text : '',
        groupRecipient: widget.recipient,
        abortTrigger: _abort.future,
        isCurrent: () => _current,
      );
      if (mounted && _current) Navigator.of(context).pop(result);
    } on NewConversationException catch (error) {
      if (!_current) return;
      setState(() {
        _error = error;
        _uncertain = error.code == NewConversationError.ambiguous;
        if (error.code == NewConversationError.contextChanged) _options = null;
      });
    } finally {
      if (_current) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings;
    final options = _options;
    final ready = options != null && !_loading && _current;
    final parameters = ready ? _parameters : const <String, int>{};
    final public = parameters['roomType'] == 3;
    final editable = ready && !_submitting && !_uncertain;
    final forced =
        options?.catalog?.forcedPreset.parameters.keys.toSet() ?? <String>{};
    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        key: const Key('conversation-creation-dialog'),
        scrollable: true,
        title: Text(
          widget.initialType == StandaloneConversationType.public
              ? strings.newConversationPublicNameDialogTitle
              : strings.newConversationNameDialogTitle,
        ),
        content: SizedBox(
          width: 440,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_loading) const Center(child: CircularProgressIndicator()),
                if (_invalidated)
                  Text(strings.newConversationErrorAccountMissing),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!.safeMessage ??
                            creationErrorText(strings, _error!.code),
                      ),
                    ),
                  ),
                if (!_loading && options == null && _current)
                  TextButton(
                    key: const Key('creation-reload'),
                    onPressed: _load,
                    child: Text(strings.retry),
                  ),
                if (ready) ...[
                  TextFormField(
                    key: const Key('creation-name'),
                    controller: _name,
                    autofocus: true,
                    enabled: editable,
                    maxLength: 200,
                    decoration: InputDecoration(
                      labelText: strings.newConversationNameLabel,
                    ),
                    validator: (text) => text == null || text.trim().isEmpty
                        ? strings.newConversationErrorRoomNameRequired
                        : null,
                  ),
                  if (options.catalog != null)
                    DropdownButtonFormField<String>(
                      key: const Key('creation-preset'),
                      initialValue: _preset,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: strings.newConversationPresetLabel,
                      ),
                      items: options.catalog!.selectablePresets
                          .map(
                            (p) => DropdownMenuItem(
                              value: p.identifier,
                              child: Text(
                                p.name.isEmpty
                                    ? strings.newConversationPresetDefault
                                    : p.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: editable
                          ? (value) {
                              if (value == null) return;
                              setState(() {
                                _preset = value;
                                if (_parameters['roomType'] != 3) {
                                  _password.clear();
                                }
                              });
                            }
                          : null,
                    ),
                  if (options.catalog != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        options.catalog!.presets
                            .firstWhere((p) => p.identifier == _preset)
                            .description,
                      ),
                    ),
                  SwitchListTile.adaptive(
                    key: const Key('creation-public'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      forced.contains('roomType')
                          ? strings.newConversationForcedSetting(
                              strings.newConversationTypePublic,
                            )
                          : strings.newConversationTypePublic,
                    ),
                    value: public,
                    onChanged: editable && !forced.contains('roomType')
                        ? (value) => setState(() {
                            _userChoices['roomType'] = value ? 3 : 2;
                            if (!value) _password.clear();
                          })
                        : null,
                  ),
                  if (public && options.supportsPassword)
                    TextFormField(
                      key: const Key('creation-password'),
                      controller: _password,
                      enabled: editable,
                      obscureText: true,
                      enableSuggestions: false,
                      autocorrect: false,
                      keyboardType: TextInputType.visiblePassword,
                      decoration: InputDecoration(
                        labelText: options.forcePasswords
                            ? strings.newConversationPasswordRequired
                            : strings.newConversationPasswordOptional,
                      ),
                      validator: (value) =>
                          options.forcePasswords && (value?.isEmpty ?? true)
                          ? strings.newConversationPasswordMissing
                          : null,
                    ),
                  if (public &&
                      options.forcePasswords &&
                      !options.supportsPassword)
                    Text(strings.newConversationErrorUnavailable),
                  if (options.catalog != null)
                    _CreationSummary(
                      parameters: {
                        ...parameters,
                        if (options.recordingConsentPolicy == 0 ||
                            options.recordingConsentPolicy == 1)
                          'recordingConsent': options.recordingConsentPolicy!,
                      },
                      forced: {
                        ...forced,
                        if (options.recordingConsentPolicy == 0 ||
                            options.recordingConsentPolicy == 1)
                          'recordingConsent',
                      },
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: Text(strings.cancel),
          ),
          if (ready && !_uncertain)
            FilledButton(
              key: const Key('creation-submit'),
              onPressed:
                  editable &&
                      !(public &&
                          options.forcePasswords &&
                          !options.supportsPassword)
                  ? _submit
                  : null,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(strings.newConversationCreate),
            ),
        ],
      ),
    );
  }
}

String creationErrorText(AppLocalizations s, NewConversationError error) =>
    switch (error) {
      NewConversationError.accountMissing ||
      NewConversationError.cancelled => s.newConversationErrorAccountMissing,
      NewConversationError.credentialMissing =>
        s.newConversationErrorCredentialMissing,
      NewConversationError.invalidSearchTerm =>
        s.newConversationErrorInvalidSearchTerm,
      NewConversationError.roomNameRequired =>
        s.newConversationErrorRoomNameRequired,
      NewConversationError.reauthenticationRequired =>
        s.newConversationErrorReauthenticationRequired,
      NewConversationError.unavailable ||
      NewConversationError.unsupported => s.newConversationErrorUnavailable,
      NewConversationError.passwordRequired =>
        s.newConversationErrorPasswordRejected,
      NewConversationError.ocsFailure => s.newConversationErrorOcsFailure,
      NewConversationError.rateLimited => s.newConversationErrorRateLimited,
      NewConversationError.serviceUnavailable =>
        s.newConversationErrorServiceUnavailable,
      NewConversationError.invalidResponse =>
        s.newConversationErrorInvalidResponse,
      NewConversationError.network => s.newConversationErrorNetwork,
      NewConversationError.contextChanged => s.newConversationPolicyChanged,
      NewConversationError.ambiguous => s.newConversationCreationUncertain,
    };
