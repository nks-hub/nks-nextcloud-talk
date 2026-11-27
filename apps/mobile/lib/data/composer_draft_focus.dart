import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_providers.dart' show ChatRoomProviderKey;

/// Consumed by the matching editor when a user opens a draft in the inbox.
final composerDraftFocusProvider = StateProvider<ChatRoomProviderKey?>(
  (_) => null,
);
