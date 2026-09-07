import 'dart:convert';
import 'dart:typed_data';

import '../bootstrap/capabilities.dart';
import '../conversations/models.dart';
import '../conversations/room_presets.dart';
import '../identifiers.dart';
import '../json_value.dart';
import '../participants/models.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

part 'policy.dart';
part 'requests.dart';
part 'response.dart';

const permissionUpdateMaximumBytes = 4 * 1024 * 1024;
const _permissionUserAgent =
    'com.nkshub.nextcloudtalk permissions-contract/0.1';

enum PermissionEditKind { roomDefault, attendee, mentions }

enum PermissionPatchMethod { set, add, remove }

/// CUSTOM=1 is a storage flag, not a user-grantable permission.
enum ConversationPermission {
  startCall(2),
  joinCall(4),
  bypassLobby(8),
  publishAudio(16),
  publishVideo(32),
  publishScreen(64),
  chat(128),
  react(256);

  const ConversationPermission(this.bit);
  final int bit;
}

/// The server adds CUSTOM to nonzero set masks; zero retains inheritance.
int normalizePermissionSet(int permissions) =>
    permissions == 0 ? 0 : permissions | 1;
