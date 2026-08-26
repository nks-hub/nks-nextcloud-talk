import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

import '../../../core/giphy_reference.dart';

part 'giphy_picker.dart';
part 'giphy_repository.dart';
part 'giphy_transport.dart';

enum GiphyAvailabilityState { available, unavailable, unknown }

final class GiphyAvailability {
  const GiphyAvailability._(this.state);

  factory GiphyAvailability.fromCapabilities(CapabilitySnapshot snapshot) {
    if (!snapshot.capabilities.containsKey('integration_giphy')) {
      return const GiphyAvailability._(GiphyAvailabilityState.unknown);
    }
    final raw = snapshot.capabilities['integration_giphy'];
    final available =
        raw is Map<String, Object?> &&
        raw['enabled'] == true &&
        raw['configured'] == true;
    return GiphyAvailability._(
      available
          ? GiphyAvailabilityState.available
          : GiphyAvailabilityState.unavailable,
    );
  }

  final GiphyAvailabilityState state;

  bool get isAvailable => state == GiphyAvailabilityState.available;
  bool get shouldProbe => state == GiphyAvailabilityState.unknown;
}

final class GiphyAuthorization {
  const GiphyAuthorization({
    required this.loginName,
    required this.appPassword,
  });

  final String loginName;
  final String appPassword;

  Map<String, String> get requestHeaders => <String, String>{
    'Accept': 'application/json',
    'OCS-APIRequest': 'true',
    'Authorization':
        'Basic ${base64Encode(utf8.encode('$loginName:$appPassword'))}',
  };

  @override
  String toString() => 'GiphyAuthorization(<redacted>)';
}

final class GiphyEntry {
  const GiphyEntry({
    required this.thumbnailUrl,
    required this.title,
    required this.subline,
    required this.resourceUrl,
  });

  final Uri thumbnailUrl;
  final String title;
  final String subline;
  final Uri resourceUrl;
}

final class GiphyPage {
  GiphyPage({required Iterable<GiphyEntry> entries, required this.cursor})
    : entries = List<GiphyEntry>.unmodifiable(entries);

  final List<GiphyEntry> entries;
  final int cursor;
}

final class GiphyThumbnail {
  GiphyThumbnail({required Uint8List body, required this.contentType})
    : body = Uint8List.fromList(body);

  final Uint8List body;
  final String contentType;
}

final class GiphyReferenceMedia {
  GiphyReferenceMedia({
    required this.resourceUrl,
    required Uint8List body,
    required this.contentType,
    required this.aspectRatio,
  }) : body = Uint8List.fromList(body);

  final Uri resourceUrl;
  final Uint8List body;
  final String contentType;
  final double? aspectRatio;
}

final class GiphyReferenceRequest {
  const GiphyReferenceRequest({
    required this.accountId,
    required this.resourceUrl,
  });

  final String accountId;
  final Uri resourceUrl;

  @override
  bool operator ==(Object other) =>
      other is GiphyReferenceRequest &&
      other.accountId == accountId &&
      other.resourceUrl == resourceUrl;

  @override
  int get hashCode => Object.hash(accountId, resourceUrl);
}

final class GiphyAttributionAsset {
  GiphyAttributionAsset({required Uint8List body, required this.contentType})
    : body = Uint8List.fromList(body);

  final Uint8List body;
  final String contentType;
}

final Uri giphyAttributionUri = Uri.parse('https://giphy.com');

const _maximumGifLogicalDimension = 4096;
const _maximumGifLogicalPixels = 4 * 1024 * 1024;

enum GiphyError {
  integrationUnavailable,
  cancelled,
  network,
  timeout,
  responseTooLarge,
  invalidResponse,
  rateLimited,
  unexpectedStatus,
}

final class GiphyException implements Exception {
  const GiphyException(this.error, {this.statusCode});

  final GiphyError error;
  final int? statusCode;

  @override
  String toString() => 'GiphyException(${error.name}, statusCode: $statusCode)';
}

abstract interface class GiphyRepository {
  Future<GiphyAttributionAsset> loadAttributionAsset({
    Future<void>? abortTrigger,
  });

  Future<GiphyPage> trending({
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  });

  Future<GiphyPage> search({
    required String term,
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  });
}
