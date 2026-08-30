part of 'nextcloud_api.dart';

final Set<int> _internalSignalingAllowedStatusCodes = <int>{
  200,
  400,
  401,
  404,
  409,
  for (var statusCode = 500; statusCode <= 599; statusCode++) statusCode,
};

mixin _NextcloudApiRooms on _HttpNextcloudApiBase {
  /// Fetches the complete user-scoped tag definition list.
  Future<FetchConversationTagsResponse> getConversationTags({
    required FetchConversationTagsRequest tagsRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', tagsRequest.uri, abortTrigger)
      ..headers.addAll({
        ...tagsRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 401, 429, 503},
      maximumBytes: conversationTagsMaximumWireBytes,
    );
    return decodeFetchConversationTagsResponse(
      request: tagsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Replaces one participant's complete tag assignment for a room.
  Future<AssignConversationTagsResponse> assignConversationTags({
    required AssignConversationTagsRequest tagsRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('POST', tagsRequest.uri, abortTrigger)
      ..headers.addAll({
        ...tagsRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyBytes = tagsRequest.bodyBytes;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: const {200, 401, 403, 404, 429, 503},
      maximumBytes: conversationTagsMaximumWireBytes,
    );
    return decodeAssignConversationTagsResponse(
      request: tagsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Resolves how a room's call would be signalled. It is the first step of
  /// any call and is deliberately separate from media handling.
  Future<SignalingSettingsResponse> getSignalingSettings({
    required SignalingSettingsRequest settingsRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', settingsRequest.uri, abortTrigger)
      ..headers.addAll({
        ...settingsRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _signalingSettingsAllowedStatusCodes,
      maximumBytes: maximumSignalingWireBytes,
      timeout: const Duration(seconds: 20),
    );
    return decodeSignalingSettingsResponse(
      request: settingsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Executes one internal-signaling long poll. The request object owns the
  /// account, room and epoch binding; this adapter only adds the matching
  /// account credential and preserves the bounded OCS response.
  Future<InternalSignalingPullResponse> pullInternalSignaling({
    required InternalSignalingPullRequest pullRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', pullRequest.uri, abortTrigger)
      ..headers.addAll({
        ...pullRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _internalSignalingAllowedStatusCodes,
      maximumBytes: maximumSignalingWireBytes,
      timeout: const Duration(seconds: 45),
    );
    return decodeInternalSignalingPullResponse(
      request: pullRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Sends a non-replayable internal-signaling batch. Callers must treat any
  /// transport failure as possibly sent; this transport never retries it.
  Future<InternalSignalingBatchResponse> sendInternalSignalingBatch({
    required InternalSignalingBatchRequest batchRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('POST', batchRequest.uri, abortTrigger)
      ..headers.addAll({
        ...batchRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = batchRequest.formFields;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _internalSignalingAllowedStatusCodes,
      maximumBytes: maximumSignalingWireBytes,
      timeout: const Duration(seconds: 20),
    );
    return decodeInternalSignalingBatchResponse(
      request: batchRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Read-only room participant list, including role and (when the server
  /// returns it) each attendee's user status.
  Future<ParticipantsResponse> getParticipants({
    required ParticipantsRequest participantsRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', participantsRequest.uri, abortTrigger)
      ..headers.addAll({
        ...participantsRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _participantsAllowedStatusCodes,
      maximumBytes: _participantsMaximumBytes,
    );
    return decodeParticipantsResponse(
      request: participantsRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Promotes, demotes or removes a single attendee. Moderator-only on the
  /// server. `attendeeId` is carried in the query string, so no request body
  /// is sent for either the POST or the DELETE variants.
  Future<ParticipantModerationResponse> moderateParticipant({
    required ParticipantModerationRequest moderationRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(
            moderationRequest.httpMethod,
            moderationRequest.uri,
            abortTrigger,
          )
          ..headers.addAll({
            ...moderationRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _participantModerationAllowedStatusCodes,
      maximumBytes: _participantsMaximumBytes,
    );
    return decodeParticipantModerationResponse(
      request: moderationRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Renames a conversation. Moderator-only on the server.
  Future<UpdateRoomNameResponse> updateRoomName({
    required UpdateRoomNameRequest updateRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('PUT', updateRequest.uri, abortTrigger)
      ..headers.addAll({
        ...updateRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = updateRequest.formBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomDetailUpdateAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeUpdateRoomNameResponse(
      request: updateRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Changes a conversation's description. Moderator-only on the server.
  Future<UpdateRoomDescriptionResponse> updateRoomDescription({
    required UpdateRoomDescriptionRequest updateRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('PUT', updateRequest.uri, abortTrigger)
      ..headers.addAll({
        ...updateRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = updateRequest.formBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomDetailUpdateAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeUpdateRoomDescriptionResponse(
      request: updateRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Sets the caller's own per-conversation notification level.
  Future<UpdateNotificationLevelResponse> updateNotificationLevel({
    required UpdateNotificationLevelRequest updateRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('POST', updateRequest.uri, abortTrigger)
      ..headers.addAll({
        ...updateRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = updateRequest.formBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomSettingsMutationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeUpdateNotificationLevelResponse(
      request: updateRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Enables or disables call notifications for the current participant.
  Future<UpdateCallNotificationLevelResponse> updateCallNotificationLevel({
    required UpdateCallNotificationLevelRequest updateRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('POST', updateRequest.uri, abortTrigger)
      ..headers.addAll({
        ...updateRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = updateRequest.formBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _callNotificationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeUpdateCallNotificationLevelResponse(
      request: updateRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Sets the moderator-controlled lifetime of new chat messages.
  Future<SetMessageExpirationResponse> setMessageExpiration({
    required SetMessageExpirationRequest expirationRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(
            expirationRequest.httpMethod,
            expirationRequest.uri,
            abortTrigger,
          )
          ..headers.addAll({
            ...expirationRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          })
          ..bodyFields = expirationRequest.formBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomAdministrationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeSetMessageExpirationResponse(
      request: expirationRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Clears every server chat message in one room and returns the replacement
  /// system message. This destructive call is direct and never retried here.
  Future<ClearRoomHistoryResponse> clearRoomHistory({
    required ClearRoomHistoryRequest clearRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(clearRequest.httpMethod, clearRequest.uri, abortTrigger)
          ..headers.addAll({
            ...clearRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _clearHistoryAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeClearRoomHistoryResponse(
      request: clearRequest,
      statusCode: payload.statusCode,
      body: payload.body,
      headers: ChatResponseHeaders.fromMap(payload.headers),
    );
  }

  /// Marks or unmarks a conversation as one of the caller's favorites.
  Future<SetFavoriteResponse> setFavorite({
    required SetFavoriteRequest favoriteRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(favoriteRequest.httpMethod, favoriteRequest.uri, abortTrigger)
          ..headers.addAll({
            ...favoriteRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomSettingsMutationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeSetFavoriteResponse(
      request: favoriteRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Changes the current participant's DND importance preference.
  Future<SetImportantResponse> setImportant({
    required SetImportantRequest importantRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(
            importantRequest.httpMethod,
            importantRequest.uri,
            abortTrigger,
          )
          ..headers.addAll({
            ...importantRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomSettingsMutationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeSetImportantResponse(
      request: importantRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Changes whether previews are hidden for the current participant.
  Future<SetSensitiveResponse> setSensitive({
    required SetSensitiveRequest sensitiveRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(
            sensitiveRequest.httpMethod,
            sensitiveRequest.uri,
            abortTrigger,
          )
          ..headers.addAll({
            ...sensitiveRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomSensitivityAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeSetSensitiveResponse(
      request: sensitiveRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Archives or unarchives a conversation for the caller.
  Future<SetArchivedResponse> setArchived({
    required SetArchivedRequest archivedRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(archivedRequest.httpMethod, archivedRequest.uri, abortTrigger)
          ..headers.addAll({
            ...archivedRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomSettingsMutationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeSetArchivedResponse(
      request: archivedRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Deletes a conversation for everyone. Moderator-only on the server.
  Future<DeleteRoomResponse> deleteRoom({
    required DeleteRoomRequest deleteRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('DELETE', deleteRequest.uri, abortTrigger)
      ..headers.addAll({
        ...deleteRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomRemovalAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeDeleteRoomResponse(
      request: deleteRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Removes the caller from a conversation. Irreversible from the client's
  /// point of view.
  Future<LeaveRoomResponse> leaveRoom({
    required LeaveRoomRequest leaveRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('DELETE', leaveRequest.uri, abortTrigger)
      ..headers.addAll({
        ...leaveRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomRemovalAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeLeaveRoomResponse(
      request: leaveRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Applies one moderator-only administration change to a conversation:
  /// public/private, password, lobby, read-only or emoji/removed avatar. The
  /// six endpoints share a status-code range and a response family, so they
  /// share one transport method too.
  Future<RoomAdministrationResponse> administerRoom({
    required RoomAdministrationRequest administrationRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _request(
            administrationRequest.httpMethod,
            administrationRequest.uri,
            abortTrigger,
          )
          ..headers.addAll({
            ...administrationRequest.headers,
            'Accept': 'application/json',
            'Authorization': _basicAuthorization(loginName, appPassword),
          });
    final formBody = administrationRequest.formBody;
    if (formBody != null) {
      request.bodyFields = formBody;
    }
    final payload = await _sendBody(
      request,
      allowedStatusCodes: administrationRequest is SetRoomSipRequest
          ? _sipAdministrationAllowedStatusCodes
          : _roomAdministrationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
    );
    return decodeRoomAdministrationResponse(
      request: administrationRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Uploads an image as the conversation avatar. Moderator-only on the
  /// server, and the only administration endpoint that is `multipart/form-data`
  /// rather than form fields.
  Future<RoomAdministrationResponse> uploadRoomAvatar({
    required SetRoomAvatarRequest avatarRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    // The contract encodes the multipart body itself, including the
    // `Content-Type` header with its boundary, so the wire format that was
    // contract-tested is the one that goes out.
    final request = _request('POST', avatarRequest.uri, abortTrigger)
      ..headers.addAll({
        ...avatarRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyBytes = avatarRequest.multipartBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _roomAdministrationAllowedStatusCodes,
      maximumBytes: _roomSettingsMaximumBytes,
      timeout: const Duration(seconds: 60),
    );
    return decodeRoomAdministrationResponse(
      request: avatarRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Reads every ban on a conversation. Moderator-only on the server.
  Future<RoomBanResponse> listBans({
    required ListBansRequest listRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('GET', listRequest.uri, abortTrigger)
      ..headers.addAll({
        ...listRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _banAllowedStatusCodes,
      maximumBytes: bansMaximumWireBytes,
    );
    return decodeListBansResponse(
      request: listRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Bans one attendee. The server removes them from the conversation in the
  /// same call. Moderator-only.
  Future<RoomBanResponse> banActor({
    required BanActorRequest banRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('POST', banRequest.uri, abortTrigger)
      ..headers.addAll({
        ...banRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      })
      ..bodyFields = banRequest.formBody;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _banAllowedStatusCodes,
      maximumBytes: bansMaximumWireBytes,
    );
    return decodeBanActorResponse(
      request: banRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }

  /// Lifts one ban. Moderator-only.
  Future<RoomBanResponse> unbanActor({
    required UnbanActorRequest unbanRequest,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _request('DELETE', unbanRequest.uri, abortTrigger)
      ..headers.addAll({
        ...unbanRequest.headers,
        'Accept': 'application/json',
        'Authorization': _basicAuthorization(loginName, appPassword),
      });
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _banAllowedStatusCodes,
      maximumBytes: bansMaximumWireBytes,
    );
    return decodeUnbanActorResponse(
      request: unbanRequest,
      statusCode: payload.statusCode,
      body: payload.body,
    );
  }
}
