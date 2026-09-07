import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/chat_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

const int _chatPermission = 128;
const int _ignoreLobbyPermission = 8;

enum CurrentLocationError {
  servicesDisabled,
  permissionDenied,
  permissionDeniedForever,
  unavailable,
}

final class CurrentLocationException implements Exception {
  const CurrentLocationException(this.code);
  final CurrentLocationError code;
}

final class SharedPosition {
  const SharedPosition(this.latitude, this.longitude);
  final double latitude;
  final double longitude;
}

final class LocatedPosition {
  const LocatedPosition({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;
}

abstract interface class LocationPlatform {
  Future<bool> isServiceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<LocatedPosition> currentPosition();
  Future<LocatedPosition?> lastKnownPosition();
}

final class GeolocatorLocationPlatform implements LocationPlatform {
  const GeolocatorLocationPlatform();

  @override
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Future<LocatedPosition> currentPosition() async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    return _position(position);
  }

  @override
  Future<LocatedPosition?> lastKnownPosition() async {
    final position = await Geolocator.getLastKnownPosition();
    return position == null ? null : _position(position);
  }

  LocatedPosition _position(Position position) => LocatedPosition(
    latitude: position.latitude,
    longitude: position.longitude,
    timestamp: position.timestamp,
  );
}

abstract interface class CurrentLocationSource {
  Future<SharedPosition> current();
}

final class GeolocatorCurrentLocationSource implements CurrentLocationSource {
  factory GeolocatorCurrentLocationSource({
    LocationPlatform platform = const GeolocatorLocationPlatform(),
  }) => GeolocatorCurrentLocationSource._(platform);

  const GeolocatorCurrentLocationSource._(this._platform);

  final LocationPlatform _platform;

  @override
  Future<SharedPosition> current() async {
    try {
      if (!await _platform.isServiceEnabled()) {
        throw const CurrentLocationException(
          CurrentLocationError.servicesDisabled,
        );
      }
      var permission = await _platform.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await _platform.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        throw const CurrentLocationException(
          CurrentLocationError.permissionDeniedForever,
        );
      }
      if (permission == LocationPermission.denied) {
        throw const CurrentLocationException(
          CurrentLocationError.permissionDenied,
        );
      }
      late LocatedPosition position;
      try {
        position = await _platform.currentPosition().timeout(
          const Duration(seconds: 16),
        );
      } on TimeoutException {
        final last = await _platform.lastKnownPosition().timeout(
          const Duration(seconds: 2),
        );
        if (last == null ||
            DateTime.now().difference(last.timestamp).abs() >
                const Duration(minutes: 5)) {
          throw const CurrentLocationException(
            CurrentLocationError.unavailable,
          );
        }
        position = last;
      }
      return SharedPosition(position.latitude, position.longitude);
    } on CurrentLocationException {
      rethrow;
    } on TimeoutException {
      throw const CurrentLocationException(CurrentLocationError.unavailable);
    } on LocationServiceDisabledException {
      throw const CurrentLocationException(
        CurrentLocationError.servicesDisabled,
      );
    } on PermissionDeniedException {
      throw const CurrentLocationException(
        CurrentLocationError.permissionDenied,
      );
    } on PlatformException {
      throw const CurrentLocationException(CurrentLocationError.unavailable);
    }
  }
}

enum LocationShareError {
  contextMissing,
  credentialMissing,
  unsupported,
  permissionDenied,
  reauthenticationRequired,
  rateLimited,
  unavailable,
  ambiguous,
  invalidResponse,
}

final class LocationShareException implements Exception {
  const LocationShareException(this.code);
  final LocationShareError code;
}

abstract interface class LocationShareSender {
  Future<ChatMessage> share({
    required String accountId,
    required String roomToken,
    required SharedPosition position,
    required String name,
    required int? threadId,
  });
}

final class LocationShareService implements LocationShareSender {
  factory LocationShareService({
    required AccountRepository accounts,
    required ChatRepository chat,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    Uuid uuid = const Uuid(),
  }) => LocationShareService._(accounts, chat, credentials, api, uuid);

  LocationShareService._(
    this._accounts,
    this._chat,
    this._credentials,
    this._api,
    this._uuid,
  );

  final AccountRepository _accounts;
  final ChatRepository _chat;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final Uuid _uuid;

  @override
  Future<ChatMessage> share({
    required String accountId,
    required String roomToken,
    required SharedPosition position,
    required String name,
    required int? threadId,
  }) async {
    var writeDispatched = false;
    final account = await _accounts.getAccount(accountId);
    final conversation = await _chat.getConversation(
      accountId: accountId,
      roomToken: roomToken,
    );
    if (account == null || conversation == null) {
      throw const LocationShareException(LocationShareError.contextMissing);
    }
    final password = await _credentials.readAppPassword(accountId);
    if (password == null || password.isEmpty) {
      throw const LocationShareException(LocationShareError.credentialMissing);
    }
    try {
      final server = ServerBase.parse(account.serverUrl);
      final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
      if (conversation.accountId != accountId ||
          room.token.value != roomToken ||
          room.readOnly != 0 ||
          // A bare 0 is the server's "use the defaults", which include chat —
          // testing the bit over it refuses every permission at once. The
          // lobby bit below deliberately gets no such benefit: the defaults do
          // not include walking past a lobby.
          (room.permissions != 0 &&
              room.permissions & _chatPermission != _chatPermission) ||
          (room.lobbyState != 0 &&
              room.permissions & _ignoreLobbyPermission !=
                  _ignoreLobbyPermission)) {
        throw const LocationShareException(LocationShareError.contextMissing);
      }
      if (threadId != null) {
        final cachedRoot = await _chat.getMessage(
          accountId: accountId,
          roomToken: roomToken,
          messageId: threadId,
        );
        if (cachedRoot == null) {
          throw const LocationShareException(LocationShareError.contextMissing);
        }
        final root = ChatMessage.fromJson(jsonDecode(cachedRoot.rawJson));
        if (root.messageId != threadId ||
            root.roomToken.value != roomToken ||
            root.isThread != true ||
            root.threadId != threadId) {
          throw const LocationShareException(LocationShareError.contextMissing);
        }
      }
      final capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: account.loginName,
        appPassword: password,
      );
      if (!capabilities.talkFeatures.contains('geo-location-sharing')) {
        throw const LocationShareException(LocationShareError.unsupported);
      }
      final request = LocationShareRequest(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: server,
        roomToken: room.token,
        latitude: position.latitude,
        longitude: position.longitude,
        name: name,
        locationSharingAvailable: true,
        threadId: threadId,
      );
      writeDispatched = true;
      final response = await _api.shareLocation(
        locationRequest: request,
        loginName: account.loginName,
        appPassword: password,
      );
      if (response.classification != LocationShareClassification.confirmed ||
          response.message == null) {
        if (response.classification ==
            LocationShareClassification.reauthenticationRequired) {
          await _chat.markReauthenticationRequired(accountId);
        }
        throw LocationShareException(switch (response.classification) {
          LocationShareClassification.reauthenticationRequired =>
            LocationShareError.reauthenticationRequired,
          LocationShareClassification.permissionDenied =>
            LocationShareError.permissionDenied,
          LocationShareClassification.rateLimited =>
            LocationShareError.rateLimited,
          LocationShareClassification.invalidInput ||
          LocationShareClassification.notFound =>
            LocationShareError.invalidResponse,
          LocationShareClassification.serviceUnavailable =>
            LocationShareError.ambiguous,
          _ => LocationShareError.unavailable,
        });
      }
      return response.message!;
    } on LocationShareException {
      rethrow;
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(accountId);
        throw const LocationShareException(
          LocationShareError.reauthenticationRequired,
        );
      }
      throw LocationShareException(
        writeDispatched
            ? LocationShareError.ambiguous
            : LocationShareError.unavailable,
      );
    } on TalkProtocolException {
      throw LocationShareException(
        writeDispatched
            ? LocationShareError.ambiguous
            : LocationShareError.invalidResponse,
      );
    } on FormatException {
      throw const LocationShareException(LocationShareError.invalidResponse);
    }
  }
}
