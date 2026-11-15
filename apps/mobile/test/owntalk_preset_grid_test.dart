import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/background_sheet.dart';

void main() {
  test('a full row of wallpaper tiles never exceeds the available width', () {
    for (var w = 200.0; w < 1200; w += 0.37) {
      final (:columns, :width) = presetTileGrid(w);
      expect(width * columns + 12 * (columns - 1), lessThanOrEqualTo(w));
    }
  });
}
