part of 'new_conversation_service.dart';

final class ConversationCreationOptions {
  const ConversationCreationOptions({
    required this.accountId,
    this.catalog,
    required this.supportsPassword,
    required this.forcePasswords,
    required this.supportsExtendedFields,
    this.recordingConsentPolicy,
  });

  final String accountId;
  final RoomPresetCatalog? catalog;
  final bool supportsPassword;
  final bool forcePasswords;
  final bool supportsExtendedFields;
  final int? recordingConsentPolicy;

  Map<String, int> effectiveParameters(
    String? preset,
    Map<String, int> choices,
  ) {
    final presets = catalog;
    return presets == null
        ? validateRoomPresetParameters(choices)
        : presets
              .resolve(
                presetIdentifier: preset ?? 'default',
                userChoices: choices,
              )
              .parameters;
  }
}

final class ConversationCreationResult {
  const ConversationCreationResult({
    required this.roomToken,
    this.invalidParticipants = const {},
  });

  final ConversationToken roomToken;
  final Map<String, List<String>> invalidParticipants;
  int get failedInvitationCount =>
      invalidParticipants.values.fold(0, (n, values) => n + values.length);
}

extension _PreparedConversationCreation on HttpNewConversationService {
  Future<ConversationCreationOptions> _prepareCreation(
    String accountId,
    Future<void>? abort,
    bool Function()? isCurrent,
  ) async {
    var cancelled = false;
    abort?.then((_) => cancelled = true);
    void check() {
      if (cancelled || !(isCurrent?.call() ?? true)) {
        throw const NewConversationException(NewConversationError.cancelled);
      }
    }

    check();
    final identity = await _resolveCredentials(accountId);
    check();
    try {
      final read = await _api.getAuthenticatedCapabilitiesWithSource(
        server: identity.server,
        loginName: identity.loginName,
        appPassword: identity.appPassword,
        abortTrigger: abort,
        forceRefresh: true,
      );
      check();
      final capabilities = read.snapshot;
      if (!capabilities.hasTalk) {
        throw const NewConversationException(NewConversationError.unsupported);
      }
      final spreed = capabilities.capabilities['spreed'];
      if (spreed is! Map) {
        throw const NewConversationException(
          NewConversationError.invalidResponse,
        );
      }
      final config = spreed['config'];
      final conversations = config is Map ? config['conversations'] : null;
      final call = config is Map ? config['call'] : null;
      final consentPolicy = call is Map ? call['recording-consent'] : null;
      if ((call != null && call is! Map) ||
          (call is Map &&
              call.containsKey('recording-consent') &&
              (consentPolicy is! int ||
                  !const {0, 1, 2}.contains(consentPolicy)))) {
        throw const NewConversationException(
          NewConversationError.invalidResponse,
        );
      }
      if (conversations != null && conversations is! Map) {
        throw const NewConversationException(
          NewConversationError.invalidResponse,
        );
      }
      final forced = conversations is Map
          ? conversations['force-passwords']
          : null;
      if (conversations is Map &&
          conversations.containsKey('force-passwords') &&
          forced is! bool) {
        throw const NewConversationException(
          NewConversationError.invalidResponse,
        );
      }
      final catalog = capabilities.supportsTalk('conversation-presets')
          ? await _api.getRoomPresets(
              request: RoomPresetsRequest(
                accountId: AccountId.parse(accountId),
                server: identity.server,
                capabilities: capabilities,
              ),
              loginName: identity.loginName,
              appPassword: identity.appPassword,
              abortTrigger: abort,
            )
          : null;
      check();
      await _validateCreationIdentity(accountId, identity);
      check();
      final options = ConversationCreationOptions(
        accountId: accountId,
        catalog: catalog,
        supportsPassword: capabilities.supportsTalk(
          'conversation-creation-password',
        ),
        forcePasswords: forced == true,
        recordingConsentPolicy: consentPolicy as int?,
        supportsExtendedFields: capabilities.supportsTalk(
          'conversation-creation-all',
        ),
      );
      if (catalog != null && !options.supportsExtendedFields) {
        throw const NewConversationException(NewConversationError.unsupported);
      }
      _creationCredentials[options] = identity;
      return options;
    } on NextcloudApiException {
      check();
      throw const NewConversationException(NewConversationError.network);
    } on TalkProtocolException {
      throw const NewConversationException(
        NewConversationError.invalidResponse,
      );
    }
  }

  Future<void> _validateCreationIdentity(
    String id,
    _AccountCredentials expected,
  ) async {
    final account = await _accounts.getAccount(id);
    final current = await _resolveCredentials(id);
    if (account == null ||
        !account.selected ||
        current.server != expected.server ||
        current.loginName != expected.loginName ||
        current.appPassword != expected.appPassword) {
      throw const NewConversationException(NewConversationError.contextChanged);
    }
  }

  Future<ConversationCreationResult> _createPrepared({
    required ConversationCreationOptions options,
    required String roomName,
    required String? presetIdentifier,
    required Map<String, int> userParameters,
    required String password,
    required ConversationRecipient? groupRecipient,
    required Future<void>? abortTrigger,
    required bool Function()? isCurrent,
  }) async {
    final identity = _creationCredentials[options];
    if (identity == null) {
      throw const NewConversationException(NewConversationError.contextChanged);
    }
    if (_creationInFlight[options] == true) {
      throw const NewConversationException(NewConversationError.ambiguous);
    }
    _creationInFlight[options] = true;
    var dispatched = false;
    var definitiveRejection = false;
    var cancelled = false;
    abortTrigger?.then((_) => cancelled = true);
    void check() {
      if (cancelled || !(isCurrent?.call() ?? true)) {
        throw NewConversationException(
          dispatched
              ? NewConversationError.ambiguous
              : NewConversationError.cancelled,
        );
      }
    }

    try {
      check();
      await _validateCreationIdentity(options.accountId, identity);
      final fresh = await _prepareCreation(
        options.accountId,
        abortTrigger,
        isCurrent,
      );
      if (!_sameCreationPolicy(options, fresh)) {
        throw const NewConversationException(
          NewConversationError.contextChanged,
        );
      }
      check();
      if (roomName.trim().isEmpty) {
        throw const NewConversationException(
          NewConversationError.roomNameRequired,
        );
      }
      if (groupRecipient != null &&
          groupRecipient.shareType != RecipientShareType.group) {
        throw const NewConversationException(
          NewConversationError.invalidResponse,
        );
      }
      final values = options.effectiveParameters(
        presetIdentifier,
        userParameters,
      );
      if ((!options.supportsExtendedFields &&
              userParameters.keys.any((key) => key != 'roomType')) ||
          (options.catalog == null && presetIdentifier != null)) {
        throw const NewConversationException(NewConversationError.unsupported);
      }
      final public = values['roomType'] == 3;
      if (public && options.forcePasswords && !options.supportsPassword) {
        throw const NewConversationException(NewConversationError.unsupported);
      }
      if (public && options.forcePasswords && password.isEmpty) {
        throw const NewConversationException(
          NewConversationError.passwordRequired,
        );
      }
      final request = CreateConversationRequest(
        accountId: AccountId.parse(options.accountId),
        requestId: ConversationRequestId.parse(_uuid.v4()),
        server: identity.server,
        roomType: public
            ? CreateConversationRoomType.public
            : CreateConversationRoomType.group,
        roomName: roomName.trim(),
        inviteId: groupRecipient?.id,
        inviteSource: groupRecipient == null ? null : 'groups',
        password: public && options.supportsPassword ? password : null,
        presetIdentifier: options.catalog == null
            ? null
            : presetIdentifier ?? 'default',
        presetParameters: options.supportsExtendedFields ? values : const {},
        creationPasswordAvailable: options.supportsPassword,
        creationAllAvailable: options.supportsExtendedFields,
        presetsAvailable: options.catalog != null,
        forcePasswords: options.forcePasswords,
      );
      await _validateCreationIdentity(options.accountId, identity);
      check();
      dispatched = true;
      final response = await _api.createConversation(
        createRequest: request,
        loginName: identity.loginName,
        appPassword: identity.appPassword,
        abortTrigger: abortTrigger,
      );
      check();
      await _validateCreationIdentity(options.accountId, identity);
      check();
      if (response is CreateConversationSuccess) {
        return ConversationCreationResult(
          roomToken: response.room.token,
          invalidParticipants: response.invalidParticipants,
        );
      }
      definitiveRejection = true;
      if (response is CreateConversationRejected) {
        final hint = response.message;
        final safeHint =
            hint != null && (password.isEmpty || !hint.contains(password))
            ? hint.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim()
            : null;
        throw NewConversationException(
          response.error == 'password'
              ? NewConversationError.passwordRequired
              : NewConversationError.ocsFailure,
          safeMessage: response.error == 'password' ? safeHint : null,
        );
      }
      if (response is CreateConversationReauthenticationRequired) {
        throw const NewConversationException(
          NewConversationError.reauthenticationRequired,
        );
      }
      if (response is CreateConversationHttpFailure) {
        if (response.kind ==
            CreateConversationHttpFailureKind.serviceUnavailable) {
          definitiveRejection = false;
          throw const NewConversationException(NewConversationError.ambiguous);
        }
        throw NewConversationException(
          response.kind == CreateConversationHttpFailureKind.rateLimited
              ? NewConversationError.rateLimited
              : NewConversationError.serviceUnavailable,
        );
      }
      throw const NewConversationException(NewConversationError.ocsFailure);
    } on NewConversationException {
      if (dispatched && !definitiveRejection) {
        throw const NewConversationException(NewConversationError.ambiguous);
      }
      rethrow;
    } on NextcloudApiException {
      throw NewConversationException(
        dispatched
            ? NewConversationError.ambiguous
            : NewConversationError.network,
      );
    } on TalkProtocolException {
      throw NewConversationException(
        dispatched
            ? NewConversationError.ambiguous
            : NewConversationError.invalidResponse,
      );
    } finally {
      if (!dispatched || definitiveRejection) {
        _creationInFlight[options] = false;
      }
    }
  }
}

bool _sameCreationPolicy(
  ConversationCreationOptions a,
  ConversationCreationOptions b,
) {
  if (a.supportsPassword != b.supportsPassword ||
      a.forcePasswords != b.forcePasswords ||
      a.recordingConsentPolicy != b.recordingConsentPolicy ||
      a.supportsExtendedFields != b.supportsExtendedFields) {
    return false;
  }
  Map<String, Object?> policy(RoomPresetCatalog? catalog) => {
    if (catalog != null)
      for (final p
          in (catalog.presets.toList()
            ..sort((a, b) => a.identifier.compareTo(b.identifier))))
        p.identifier: {
          for (final key in p.parameters.keys.toList()..sort())
            key: p.parameters[key],
        },
  };
  return (a.catalog == null) == (b.catalog == null) &&
      jsonEncode(policy(a.catalog)) == jsonEncode(policy(b.catalog));
}
