import 'package:integration_test/integration_test.dart';
import 'gui_test_guard.dart';

import '../test/authenticated_image_viewer_test.dart' as viewer;
import '../test/chat_room_pane_test.dart' as chat;

// Pass --no-uninstall to flutter test; its default removes device app data.
void main() {
  requireGuiTestHost();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  chat.main(albumsOnly: true);
  viewer.main(galleryOnly: true);
}
