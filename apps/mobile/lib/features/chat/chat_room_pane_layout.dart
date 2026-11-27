part of 'chat_room_pane.dart';

enum _ChatRoomRegion { notices, timeline, composer }

final class _ChatRoomLayout extends StatelessWidget {
  const _ChatRoomLayout({
    required this.notices,
    required this.timeline,
    required this.composer,
  });

  final List<Widget> notices;
  final Widget timeline;
  final List<Widget> composer;

  @override
  Widget build(BuildContext context) => CustomMultiChildLayout(
    key: const Key('chat-room-pane'),
    delegate: _ChatRoomLayoutDelegate(),
    children: [
      LayoutId(
        id: _ChatRoomRegion.notices,
        child: SingleChildScrollView(
          primary: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: notices),
        ),
      ),
      LayoutId(id: _ChatRoomRegion.timeline, child: timeline),
      LayoutId(
        id: _ChatRoomRegion.composer,
        child: SingleChildScrollView(
          primary: false,
          reverse: true,
          child: Column(mainAxisSize: MainAxisSize.min, children: composer),
        ),
      ),
    ],
  );
}

final class _ChatRoomLayoutDelegate extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    BoxConstraints viewport(double height) => BoxConstraints(
      minWidth: size.width,
      maxWidth: size.width,
      maxHeight: height,
    );

    // A 48 dp control and the composer's 16 dp padding must fit first.
    const actionHeight = 48.0;
    const composerMinimum = actionHeight + 16.0;
    final composerBudget = math.max(
      math.min(composerMinimum, size.height),
      size.height - actionHeight,
    );
    final composer = layoutChild(
      _ChatRoomRegion.composer,
      viewport(composerBudget),
    );
    final remaining = size.height - composer.height;
    final timelineMinimum = math.min(actionHeight, remaining / 2);
    final notices = layoutChild(
      _ChatRoomRegion.notices,
      viewport(remaining - timelineMinimum),
    );
    layoutChild(
      _ChatRoomRegion.timeline,
      BoxConstraints.tight(Size(size.width, remaining - notices.height)),
    );
    positionChild(_ChatRoomRegion.notices, Offset.zero);
    positionChild(_ChatRoomRegion.timeline, Offset(0, notices.height));
    positionChild(_ChatRoomRegion.composer, Offset(0, remaining));
  }

  @override
  bool shouldRelayout(_ChatRoomLayoutDelegate oldDelegate) => false;
}
