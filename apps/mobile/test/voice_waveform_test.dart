import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/voice_waveform.dart';

void main() {
  test('voice peaks come from PCM samples and skip padded metadata', () {
    final folder = Directory.systemTemp.createTempSync('owntalk-wave-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = File('${folder.path}/voice.wav');
    final wav = Uint8List(58);
    final fields = ByteData.sublistView(wav);
    void tag(int at, String name) => wav.setRange(at, at + 4, name.codeUnits);
    tag(0, 'RIFF');
    fields.setUint32(4, wav.length - 8, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'JUNK');
    fields.setUint32(16, 1, Endian.little);
    tag(22, 'fmt ');
    fields.setUint32(26, 16, Endian.little);
    fields.setUint16(30, 1, Endian.little);
    fields.setUint16(32, 1, Endian.little);
    fields.setUint16(42, 2, Endian.little);
    fields.setUint16(44, 16, Endian.little);
    tag(46, 'data');
    fields.setUint32(50, 4, Endian.little);
    fields.setInt16(56, -32768, Endian.little);
    file.writeAsBytesSync(wav);
    expect(readVoicePeaks(file.path), [0.0, 1.0]);
    file.writeAsBytesSync(wav.sublist(0, 56));
    expect(readVoicePeaks(file.path), isNull);
    file.writeAsStringSync('other audio format');
    expect(readVoicePeaks(file.path), isNull);
  });
}
