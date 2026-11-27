import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Samples the 16-bit PCM WAV files produced by the recorder. Other audio
/// formats keep the normal seek bar. Run in an isolate after the file arrives.
List<double>? readVoicePeaks(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final length = file.lengthSync();
    final header = file.readSync(12);
    if (header.length != 12 ||
        String.fromCharCodes(header, 0, 4) != 'RIFF' ||
        String.fromCharCodes(header, 8, 12) != 'WAVE') {
      return null;
    }
    var frameBytes = 0;
    var offset = 12;
    for (var chunk = 0; chunk < 64 && offset + 8 <= length; chunk++) {
      file.setPositionSync(offset);
      final chunkHeader = file.readSync(8);
      if (chunkHeader.length != 8) return null;
      final size = ByteData.sublistView(
        chunkHeader,
      ).getUint32(4, Endian.little);
      final data = offset + 8;
      if (data + size > length) return null;
      final name = String.fromCharCodes(chunkHeader, 0, 4);
      if (name == 'fmt ' && size >= 16) {
        final bytes = file.readSync(16);
        if (bytes.length != 16) return null;
        final fmt = ByteData.sublistView(bytes);
        frameBytes = fmt.getUint16(12, Endian.little);
        if (fmt.getUint16(0, Endian.little) != 1 ||
            fmt.getUint16(14, Endian.little) != 16 ||
            frameBytes == 0 ||
            frameBytes != 2 * fmt.getUint16(2, Endian.little))
          return null;
      }
      if (name == 'data' && frameBytes > 0) {
        final frames = size ~/ frameBytes;
        if (frames == 0) return null;
        final bars = math.min(frames, 36);
        final peaks = <double>[];
        for (var i = 0; i < bars; i++) {
          final start = i * frames ~/ bars;
          final end = (i + 1) * frames ~/ bars;
          final count = math.min(end - start, 128);
          final middle = start + (end - start - count) ~/ 2;
          file.setPositionSync(data + middle * frameBytes);
          final bytes = file.readSync(math.min(count * frameBytes, 1024));
          final samples = ByteData.sublistView(bytes);
          var peak = 0;
          for (var j = 0; j + 1 < bytes.length; j += 2) {
            peak = math.max(peak, samples.getInt16(j, Endian.little).abs());
          }
          peaks.add(math.sqrt(peak / 32768));
        }
        return peaks;
      }
      offset = data + size + size % 2;
    }
  } on FileSystemException {
    return null;
  } finally {
    file?.closeSync();
  }
  return null;
}
