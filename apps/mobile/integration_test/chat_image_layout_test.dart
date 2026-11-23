import 'package:integration_test/integration_test.dart';
import 'gui_test_guard.dart';

import '../test/chat_room_pane_test.dart' as chat;

/// Runs the same image and history assertions in a native window or device.
void main() {
  requireGuiTestHost();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  chat.main(imagesOnly: true);
}
