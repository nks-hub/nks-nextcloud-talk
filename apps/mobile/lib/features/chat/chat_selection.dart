import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Groups the selectable text under [child] into one selectable whose copied
/// text joins the selected parts with [separator].
///
/// Flutter's selection joins the text of neighbouring widgets with nothing
/// between them, so a copied list or two copied messages came out as one
/// run-on word. Outside a selection area there is nothing to group and the
/// child is returned as is.
final class ChatSelectionJoin extends StatefulWidget {
  const ChatSelectionJoin({
    super.key,
    required this.separator,
    required this.child,
    this.breakBefore = false,
  });

  final String separator;
  final Widget child;

  /// Starts the copied text on a new line when the selection began above
  /// this widget, so a selection running across several messages copies one
  /// message per line. Only the leading edge decides: ending a drag a little
  /// below the text is common and must not add a stray line break.
  final bool breakBefore;

  @override
  State<ChatSelectionJoin> createState() => _ChatSelectionJoinState();
}

final class _ChatSelectionJoinState extends State<ChatSelectionJoin> {
  late final _JoiningSelectionDelegate _delegate = _JoiningSelectionDelegate(
    widget.separator,
    widget.breakBefore ? _globalTop : null,
  );

  double? _globalTop() {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero).dy
        : null;
  }

  @override
  void didUpdateWidget(ChatSelectionJoin oldWidget) {
    super.didUpdateWidget(oldWidget);
    _delegate
      ..separator = widget.separator
      ..globalTop = widget.breakBefore ? _globalTop : null;
  }

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (SelectionContainer.maybeOf(context) == null) {
      return widget.child;
    }
    return SelectionContainer(delegate: _delegate, child: widget.child);
  }
}

final class _JoiningSelectionDelegate extends StaticSelectionContainerDelegate {
  _JoiningSelectionDelegate(this.separator, this.globalTop);

  String separator;
  double? Function()? globalTop;
  double? _startY;
  double? _endY;
  bool _all = false;

  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    if (event.type == SelectionEventType.startEdgeUpdate) {
      _startY = event.globalPosition.dy;
    } else {
      _endY = event.globalPosition.dy;
    }
    _all = false;
    return super.handleSelectionEdgeUpdate(event);
  }

  @override
  SelectionResult handleSelectAll(SelectAllSelectionEvent event) {
    _all = true;
    return super.handleSelectAll(event);
  }

  @override
  SelectionResult handleClearSelection(ClearSelectionEvent event) {
    _forgetEdges();
    return super.handleClearSelection(event);
  }

  @override
  SelectionResult handleSelectWord(SelectWordSelectionEvent event) {
    _forgetEdges();
    return super.handleSelectWord(event);
  }

  @override
  SelectionResult handleSelectParagraph(SelectParagraphSelectionEvent event) {
    _forgetEdges();
    return super.handleSelectParagraph(event);
  }

  void _forgetEdges() {
    _startY = _endY = null;
    _all = false;
  }

  bool get _startsAbove {
    final top = globalTop?.call();
    if (top == null) {
      return false;
    }
    if (_all) {
      return true;
    }
    final start = _startY;
    final end = _endY;
    return start != null && end != null && (start < end ? start : end) < top;
  }

  @override
  SelectedContent? getSelectedContent() {
    final parts = <String>[
      for (final selectable in selectables)
        if (selectable.getSelectedContent()?.plainText case final text?
            when text.isNotEmpty)
          text,
    ];
    if (parts.isEmpty) {
      return null;
    }
    final text = parts.join(separator);
    return SelectedContent(plainText: _startsAbove ? '\n$text' : text);
  }
}
