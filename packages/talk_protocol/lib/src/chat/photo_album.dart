/// Each photo keeps its own replay identity while sharing an album id.
final class ChatPhotoAlbumReference {
  factory ChatPhotoAlbumReference({
    required String albumId,
    required int index,
    required int count,
  }) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(albumId) ||
        count < 2 ||
        count > 9999 ||
        index < 0 ||
        index >= count) {
      throw ArgumentError('Invalid photo album reference');
    }
    return ChatPhotoAlbumReference._(albumId, index, count);
  }

  const ChatPhotoAlbumReference._(this.albumId, this.index, this.count);

  final String albumId;
  final int index;
  final int count;

  String get referenceId =>
      'otg1.$albumId.${index.toString().padLeft(4, '0')}.'
      '${count.toString().padLeft(4, '0')}';

  static ChatPhotoAlbumReference? tryParse(String value) {
    final match = RegExp(
      r'^otg1\.([0-9a-f]{32})\.(\d{4})\.(\d{4})$',
    ).firstMatch(value);
    if (match == null) return null;
    final index = int.parse(match[2]!);
    final count = int.parse(match[3]!);
    if (count < 2 || index >= count) return null;
    return ChatPhotoAlbumReference._(match[1]!, index, count);
  }

  @override
  String toString() => 'ChatPhotoAlbumReference(<redacted>)';
}
