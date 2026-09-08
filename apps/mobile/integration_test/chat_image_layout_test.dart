import 'package:integration_test/integration_test.dart';

import '../test/chat_room_pane_test.dart' as chat;

/// Runs the same image and history assertions in a native window or device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  chat.main(imagesOnly: true);
}
