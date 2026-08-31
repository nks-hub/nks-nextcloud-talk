part of 'room_details_screen.dart';

extension _RoomDetailsSharedItems on _RoomDetailsScreenState {
  bool get _canOpenSharedItems {
    final room = _room;
    if (room == null || !_talkFeatures.contains(_sharedItemsCapability)) {
      return false;
    }
    return room.remoteServer?.isNotEmpty != true ||
        _talkFeatures.contains(_federatedSharedItemsCapability);
  }

  void _openSharedItems() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/conversation/shared-items'),
        builder: (context) => SharedItemsScreen(
          account: widget.account,
          conversation: widget.conversation,
        ),
      ),
    );
  }
}
