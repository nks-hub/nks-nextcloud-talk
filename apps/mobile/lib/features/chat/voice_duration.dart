/// Formats voice playback times as m:ss or h:mm:ss.
String formatVoiceDuration(Duration value) {
  final total = value.isNegative ? Duration.zero : value;
  final seconds = (total.inSeconds % 60).toString().padLeft(2, '0');
  final minutes = total.inMinutes % 60;
  if (total.inHours == 0) {
    return '$minutes:$seconds';
  }
  return '${total.inHours}:${minutes.toString().padLeft(2, '0')}:$seconds';
}
