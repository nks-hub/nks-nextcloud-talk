import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:talk_protocol/talk_protocol.dart';

import '../../network/attachment_transport.dart';
import '../media/durable_attachment_source_store.dart';

const int maximumContactVCardBytes = 2 * 1024 * 1024;

enum ContactPickerFailure { permissionDenied, unavailable, invalidSelection }

final class ContactPickerException implements Exception {
  const ContactPickerException(this.failure);

  final ContactPickerFailure failure;

  @override
  String toString() => 'ContactPickerException(${failure.name})';
}

final class ContactSelection {
  const ContactSelection({required this.displayName, required this.vcard});

  final String displayName;
  final Uint8List vcard;
}

abstract interface class ContactSelectionBackend {
  Future<ContactSelection?> selectContact();
}

final class PlatformContactSelectionBackend implements ContactSelectionBackend {
  const PlatformContactSelectionBackend();

  static const channelName = 'com.nkshub.nextcloudtalk/contact_picker';
  static const _channel = MethodChannel(channelName);

  @override
  Future<ContactSelection?> selectContact() async {
    final Object? result;
    try {
      result = await _channel.invokeMethod<Object?>('pickContact');
    } on PlatformException catch (error) {
      throw ContactPickerException(switch (error.code) {
        'permission_denied' => ContactPickerFailure.permissionDenied,
        'picker_unavailable' ||
        'picker_in_progress' => ContactPickerFailure.unavailable,
        _ => ContactPickerFailure.invalidSelection,
      });
    } on MissingPluginException {
      throw const ContactPickerException(ContactPickerFailure.unavailable);
    }
    if (result == null) {
      return null;
    }
    if (result is! Map<Object?, Object?>) {
      throw const ContactPickerException(ContactPickerFailure.invalidSelection);
    }
    final displayName = result['displayName'];
    final vcard = result['vcard'];
    if (displayName is! String || vcard is! Uint8List) {
      throw const ContactPickerException(ContactPickerFailure.invalidSelection);
    }
    return ContactSelection(displayName: displayName, vcard: vcard);
  }
}

final class DurableContactAttachmentPicker {
  const DurableContactAttachmentPicker({
    required this.backend,
    required this.store,
  });

  final ContactSelectionBackend backend;
  final DurableAttachmentSourceStore store;

  Future<PreparedAttachmentSource?> pick({
    required String fallbackDisplayName,
    required AttachmentCancellationSignal cancellationSignal,
  }) async {
    final selection = await backend.selectContact();
    if (selection == null || cancellationSignal.isCancelled) {
      return null;
    }
    final maximumBytes = store.maximumSourceBytes < maximumContactVCardBytes
        ? store.maximumSourceBytes
        : maximumContactVCardBytes;
    _validateSingleVCard(selection.vcard, maximumBytes);
    final displayName = _vCardDisplayName(
      selection.displayName,
      fallbackDisplayName,
    );
    return store.copyFromStream(
      stream: Stream<List<int>>.value(selection.vcard),
      mimeType: 'text/vcard',
      displayName: displayName,
      expectedByteLength: selection.vcard.length,
      cancellationSignal: cancellationSignal,
    );
  }
}

void _validateSingleVCard(Uint8List bytes, int maximumBytes) {
  if (bytes.isEmpty || bytes.length > maximumBytes) {
    throw const ContactPickerException(ContactPickerFailure.invalidSelection);
  }
  final String text;
  try {
    text = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const ContactPickerException(ContactPickerFailure.invalidSelection);
  }
  final lines = const LineSplitter()
      .convert(text)
      .map((line) => line.trimRight())
      .toList(growable: false);
  final versions = lines.where(
    (line) => line == 'VERSION:3.0' || line == 'VERSION:4.0',
  );
  final hasFormattedName = lines.any(
    (line) => RegExp(r'^FN(?:;[^:]*)?:.+$').hasMatch(line),
  );
  if (lines.isEmpty ||
      lines.first != 'BEGIN:VCARD' ||
      lines.last != 'END:VCARD' ||
      lines.where((line) => line == 'BEGIN:VCARD').length != 1 ||
      lines.where((line) => line == 'END:VCARD').length != 1 ||
      versions.length != 1 ||
      !hasFormattedName) {
    throw const ContactPickerException(ContactPickerFailure.invalidSelection);
  }
}

String _vCardDisplayName(String value, String fallback) {
  var name = p.basename(value.trim());
  if (name.toLowerCase().endsWith('.vcf')) {
    name = name.substring(0, name.length - 4);
  }
  name = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.isEmpty || name == '.' || name == '..') {
    name = fallback.trim();
  }
  if (name.isEmpty) {
    throw const ContactPickerException(ContactPickerFailure.invalidSelection);
  }
  if (name.length > 116) {
    name = name.substring(0, 116).trimRight();
  }
  return '$name.vcf';
}
