import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/profile/profile_models.dart';

void main() {
  int seconds(DateTime value) =>
      value.millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;

  // A Sunday on purpose: `week` has to reach the end of the current week, and
  // Sunday is the day where an off-by-one lands in the past instead of the
  // future.
  final sunday = DateTime(2026, 8, 30, 14, 0);

  test('never sends no expiry at all', () {
    expect(StatusExpiry.never.clearAt(sunday), isNull);
  });

  test('the relative choices add their own duration', () {
    expect(
      StatusExpiry.halfHour.clearAt(sunday),
      seconds(DateTime(2026, 8, 30, 14, 30)),
    );
    expect(
      StatusExpiry.hour.clearAt(sunday),
      seconds(DateTime(2026, 8, 30, 15, 0)),
    );
    expect(
      StatusExpiry.fourHours.clearAt(sunday),
      seconds(DateTime(2026, 8, 30, 18, 0)),
    );
  });

  test('today ends at the next midnight, not 24 hours later', () {
    expect(
      StatusExpiry.today.clearAt(sunday),
      seconds(DateTime(2026, 8, 31)),
    );
  });

  test('week ends after the last day of the current week', () {
    // 30. 8. 2026 is a Sunday (weekday 7), so the week ends that midnight.
    expect(sunday.weekday, DateTime.sunday);
    expect(StatusExpiry.week.clearAt(sunday), seconds(DateTime(2026, 8, 31)));

    // From a Monday the same choice has to reach the following Monday.
    final monday = DateTime(2026, 8, 31, 9, 0);
    expect(monday.weekday, DateTime.monday);
    expect(StatusExpiry.week.clearAt(monday), seconds(DateTime(2026, 9, 7)));
  });

  test('every choice lands in the future', () {
    for (final expiry in StatusExpiry.values) {
      final resolved = expiry.clearAt(sunday);
      if (resolved == null) {
        continue;
      }
      expect(
        resolved,
        greaterThan(seconds(sunday)),
        reason: '${expiry.name} must expire after it was set',
      );
    }
  });
}
