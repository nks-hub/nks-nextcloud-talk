import 'package:integration_test/integration_test.dart';

import '../test/authenticated_image_viewer_test.dart' as viewer;
import '../test/chat_room_pane_test.dart' as chat;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  chat.main(imagesOnly: true);
  viewer.main();
}
