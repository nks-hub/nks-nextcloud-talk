import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum ChatAttachmentMobileSaveResult { saved, cancelled }

enum ChatAttachmentMobileSaveFailure {
  permissionDenied,
  storageFailed,
  invalidSource,
  tooLarge,
  inProgress,
  unavailable,
}

final class ChatAttachmentMobileSaveException implements Exception {
  const ChatAttachmentMobileSaveException(this.failure);

  final ChatAttachmentMobileSaveFailure failure;

  @override
  String toString() => 'ChatAttachmentMobileSaveException(${failure.name})';
}

abstract interface class ChatAttachmentMobileSaver {
  Future<ChatAttachmentMobileSaveResult> save({
    required String sourcePath,
    required String fileName,
    required String contentType,
  });
}

final class MethodChannelChatAttachmentMobileSaver
    implements ChatAttachmentMobileSaver {
  MethodChannelChatAttachmentMobileSaver({
    MethodChannel channel = const MethodChannel(channelName),
    bool? supported,
  }) : this._(
         channel,
         supported ??
             (!kIsWeb &&
                 (defaultTargetPlatform == TargetPlatform.android ||
                     defaultTargetPlatform == TargetPlatform.iOS)),
       );

  MethodChannelChatAttachmentMobileSaver._(this._channel, this._supported);

  static const channelName = 'com.nkshub.nextcloudtalk/attachment_saver';

  final MethodChannel _channel;
  final bool _supported;
  bool _inFlight = false;

  @override
  Future<ChatAttachmentMobileSaveResult> save({
    required String sourcePath,
    required String fileName,
    required String contentType,
  }) async {
    if (!_supported) {
      throw const ChatAttachmentMobileSaveException(
        ChatAttachmentMobileSaveFailure.unavailable,
      );
    }
    if (_inFlight) {
      throw const ChatAttachmentMobileSaveException(
        ChatAttachmentMobileSaveFailure.inProgress,
      );
    }
    _inFlight = true;
    try {
      final result = await _channel.invokeMethod<String>('save', {
        'sourcePath': sourcePath,
        'fileName': fileName,
        'contentType': contentType,
      });
      return switch (result) {
        'saved' => ChatAttachmentMobileSaveResult.saved,
        'cancelled' => ChatAttachmentMobileSaveResult.cancelled,
        _ => throw const ChatAttachmentMobileSaveException(
          ChatAttachmentMobileSaveFailure.unavailable,
        ),
      };
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') {
        return ChatAttachmentMobileSaveResult.cancelled;
      }
      throw ChatAttachmentMobileSaveException(switch (error.code) {
        'permission_denied' => ChatAttachmentMobileSaveFailure.permissionDenied,
        'storage_failed' => ChatAttachmentMobileSaveFailure.storageFailed,
        'invalid_source' => ChatAttachmentMobileSaveFailure.invalidSource,
        'too_large' => ChatAttachmentMobileSaveFailure.tooLarge,
        'save_in_progress' => ChatAttachmentMobileSaveFailure.inProgress,
        _ => ChatAttachmentMobileSaveFailure.unavailable,
      });
    } on MissingPluginException {
      throw const ChatAttachmentMobileSaveException(
        ChatAttachmentMobileSaveFailure.unavailable,
      );
    } finally {
      _inFlight = false;
    }
  }
}
