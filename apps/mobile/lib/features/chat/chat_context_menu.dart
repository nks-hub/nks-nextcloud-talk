import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// One command of the right-click menu over a message.
final class ChatContextMenuEntry {
  const ChatContextMenuEntry({
    required this.key,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  final Key key;
  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

/// Gathers what a right click landed on before the message decides which
/// menu to show.
///
/// Pointer-down listeners run from the deepest widget outwards, so a link or
/// a picture under the pointer offers its own commands first and the timeline
/// records where the click was. Both are stamped with the pointer event, and
/// [take] hands them out only as a pair from that same click; anything left
/// over from an earlier click is dropped.
final class ChatContextMenuCollector {
  _Click? _click;
  _Click? _offered;
  List<ChatContextMenuEntry> _entries = const [];

  void offer(PointerDownEvent event, List<ChatContextMenuEntry> entries) {
    _offered = _Click.of(event);
    _entries = entries;
  }

  /// Remembers a right click; any other press forgets it, so a click that
  /// opened no menu cannot turn a later long press into one.
  void record(PointerDownEvent event) {
    _click = _isSecondary(event) ? _Click.of(event) : null;
  }

  /// The position and target commands of the right click being handled, or
  /// null when the actions were asked for some other way (long press, key).
  ({Offset position, List<ChatContextMenuEntry> entries})? take() {
    final click = _click;
    final offered = _offered;
    final entries = _entries;
    _click = null;
    _offered = null;
    _entries = const [];
    if (click == null) return null;
    return (
      position: click.position,
      entries: offered == click ? entries : const <ChatContextMenuEntry>[],
    );
  }
}

final class _Click {
  const _Click(this.pointer, this.timeStamp, this.position);

  factory _Click.of(PointerDownEvent event) =>
      _Click(event.pointer, event.timeStamp, event.position);

  final int pointer;
  final Duration timeStamp;
  final Offset position;

  @override
  bool operator ==(Object other) =>
      other is _Click &&
      other.pointer == pointer &&
      other.timeStamp == timeStamp;

  @override
  int get hashCode => Object.hash(pointer, timeStamp);
}

bool _isSecondary(PointerDownEvent event) =>
    event.kind == PointerDeviceKind.mouse &&
    event.buttons & kSecondaryMouseButton != 0;

/// Makes [collector] reachable from the message content below it.
final class ChatContextMenuScope extends InheritedWidget {
  const ChatContextMenuScope({
    super.key,
    required this.collector,
    required super.child,
  });

  final ChatContextMenuCollector collector;

  static ChatContextMenuCollector? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChatContextMenuScope>()?.collector;

  @override
  bool updateShouldNotify(ChatContextMenuScope oldWidget) =>
      !identical(collector, oldWidget.collector);
}

/// Records every right click inside [child] in the scope's collector.
final class ChatContextMenuArea extends StatelessWidget {
  const ChatContextMenuArea({
    super.key,
    required this.collector,
    required this.child,
  });

  final ChatContextMenuCollector collector;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ChatContextMenuScope(
      collector: collector,
      child: Listener(
        onPointerDown: (event) {
          collector.record(event);
        },
        child: child,
      ),
    );
  }
}

/// Offers [entries] when a right click lands on [child], for a link or a
/// picture inside a message. Outside a [ChatContextMenuScope] it does nothing.
final class ChatContextMenuSource extends StatelessWidget {
  const ChatContextMenuSource({
    super.key,
    required this.entries,
    required this.child,
  });

  final List<ChatContextMenuEntry> Function() entries;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final collector = ChatContextMenuScope.maybeOf(context);
    if (collector == null) return child;
    return Listener(
      onPointerDown: (event) {
        if (_isSecondary(event)) collector.offer(event, entries());
      },
      child: child,
    );
  }
}

/// Shows [groups] as one menu at [position], with a divider between groups.
Future<void> showChatContextMenu({
  required BuildContext context,
  required Offset position,
  required List<List<ChatContextMenuEntry>> groups,
}) async {
  final nonEmpty = groups.where((group) => group.isNotEmpty).toList();
  if (nonEmpty.isEmpty) return;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(position);
  final chosen = await showMenu<ChatContextMenuEntry>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(local.dx, local.dy, 0, 0),
      Offset.zero & overlay.size,
    ),
    items: [
      for (var index = 0; index < nonEmpty.length; index++) ...[
        if (index > 0) const PopupMenuDivider(),
        for (final entry in nonEmpty[index])
          PopupMenuItem<ChatContextMenuEntry>(
            key: entry.key,
            value: entry,
            child: Row(
              children: [
                Icon(entry.icon, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(entry.label)),
              ],
            ),
          ),
      ],
    ],
  );
  chosen?.onSelected();
}
