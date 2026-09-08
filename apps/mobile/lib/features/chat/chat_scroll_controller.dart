import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Preserves a visible message while a reversed history view changes layout.
final class ChatScrollController extends ScrollController {
  final _rows = <int, _ChatRowExtent>{};
  double? _snapshotPixels;
  double? _snapshotViewport;
  int? _readingAnchor;
  double? _anchorTop;
  int _scopeGeneration = 0;
  bool _snapshotScheduled = false;
  @visibleForTesting
  int get debugTrackedRowCount => _rows.length;
  ({_ChatScrollPosition position, double pixels, double viewport})?
  _nextSnapshot;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _ChatScrollPosition(
    owner: this,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );

  void resetExtentTracking() {
    _scopeGeneration++;
    _snapshotScheduled = false;
    _nextSnapshot = null;
    for (final row in _rows.values) {
      row.top = null;
      row.bottom = null;
    }
    _snapshotPixels = null;
    _snapshotViewport = null;
    _readingAnchor = null;
    _anchorTop = null;
    if (hasClients) (position as _ChatScrollPosition).resetCorrection();
  }

  void _attach(int id, _RenderChatMessageExtent node) {
    (_rows[id] ??= _ChatRowExtent()).node = node;
  }

  void _detach(int id, _RenderChatMessageExtent node) {
    final row = _rows[id];
    if (row != null && identical(row.node, node)) row.node = null;
  }

  void _prepareLayout(double pixels) {
    _readingAnchor = null;
    _anchorTop = null;
    final previousPixels = _snapshotPixels;
    final viewport = _snapshotViewport;
    if (pixels <= 0 || previousPixels == null || viewport == null) return;
    final movement = pixels - previousPixels;
    double? firstTop;
    int? partialId;
    double? partialTop;
    for (final entry in _rows.entries) {
      final row = entry.value;
      if (!row.growsTowardHistory || row.top == null || row.bottom == null) {
        continue;
      }
      final top = row.top! + movement;
      final bottom = row.bottom! + movement;
      if (bottom <= 0 || top >= viewport) continue;
      if (partialTop == null || top < partialTop) {
        partialId = entry.key;
        partialTop = top;
      }
      if (top >= 0 &&
          bottom <= viewport &&
          (firstTop == null || top < firstTop)) {
        _readingAnchor = entry.key;
        firstTop = top;
      }
    }
    _readingAnchor ??= partialId;
    _anchorTop = firstTop ?? partialTop;
  }

  double? _anchorCorrection() {
    final row = _rows[_readingAnchor];
    final target = _anchorTop;
    if (row == null || target == null) return null;
    final top = _rowTop(row);
    return top == null ? null : target - top;
  }

  double? _rowTop(_ChatRowExtent row) {
    final node = row.node;
    final height = row.height;
    if (node == null || height == null || !node.attached) return null;
    RenderObject item = node;
    while (item.parent != null && item.parent is! RenderSliverMultiBoxAdaptor) {
      item = item.parent!;
    }
    final data = item.parentData;
    if (data is! SliverMultiBoxAdaptorParentData ||
        data.keptAlive ||
        data.layoutOffset == null) {
      return null;
    }
    final sliver = item.parent;
    if (sliver is! RenderSliverMultiBoxAdaptor || sliver.geometry == null) {
      return null;
    }
    final viewport = RenderAbstractViewport.maybeOf(node);
    if (viewport == null) return null;
    // Child RenderBox.size cannot be read from the viewport's layout phase.
    final origin = MatrixUtils.transformPoint(
      sliver.getTransformTo(viewport),
      Offset.zero,
    ).dy;
    final leading = data.layoutOffset! - sliver.constraints.scrollOffset;
    return row.growsTowardHistory
        ? origin + sliver.geometry!.paintExtent - leading - height
        : origin + leading;
  }

  void _measured(
    int id,
    _RenderChatMessageExtent node,
    double height,
    bool growsTowardHistory,
  ) {
    final row = _rows[id];
    if (row == null || !identical(row.node, node)) return;
    final previous = row.height;
    row.height = height;
    row.growsTowardHistory = growsTowardHistory;
    final anchor = _readingAnchor;
    if (previous == null ||
        anchor == null ||
        id < anchor ||
        !growsTowardHistory ||
        !hasClients) {
      return;
    }
    final current = position as _ChatScrollPosition;
    if (!current.haveDimensions || current.pixels <= 0) return;
    final change = height - previous;
    if (change.abs() > precisionErrorTolerance) {
      current.queueExtentCorrection(change);
    }
  }

  void _scheduleSnapshot(_ChatScrollPosition current) {
    _nextSnapshot = (
      position: current,
      pixels: current.pixels,
      viewport: current.viewportDimension,
    );
    if (_snapshotScheduled) return;
    _snapshotScheduled = true;
    final generation = _scopeGeneration;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (generation != _scopeGeneration) return;
      _snapshotScheduled = false;
      final snapshot = _nextSnapshot;
      _nextSnapshot = null;
      if (snapshot == null || !positions.contains(snapshot.position)) return;
      _snapshotPixels = snapshot.pixels;
      _snapshotViewport = snapshot.viewport;
      _rows.removeWhere((_, row) => row.node == null);
      for (final row in _rows.values) {
        row.top = _rowTop(row);
        row.bottom = row.top == null ? null : row.top! + row.height!;
      }
    });
  }

  @override
  void dispose() {
    _scopeGeneration++;
    _nextSnapshot = null;
    _rows.clear();
    super.dispose();
  }
}

final class _ChatRowExtent {
  _RenderChatMessageExtent? node;
  double? height;
  double? top;
  double? bottom;
  bool growsTowardHistory = false;
}

final class _ChatScrollPosition extends ScrollPositionWithSingleContext {
  _ChatScrollPosition({
    required this.owner,
    required super.physics,
    required super.context,
    required super.initialPixels,
    required super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final ChatScrollController owner;
  double _extentCorrection = 0;
  double _viewportCorrection = 0;
  bool _inLayout = false;

  void resetCorrection() {
    _extentCorrection = 0;
    _viewportCorrection = 0;
    _inLayout = false;
  }

  void queueExtentCorrection(double change) {
    _extentCorrection += change;
    correctBy(0);
  }

  @override
  bool applyViewportDimension(double viewportDimension) {
    if (!_inLayout) {
      _inLayout = true;
      owner._prepareLayout(pixels);
      final previous = owner._snapshotViewport;
      _viewportCorrection = pixels > 0 && previous != null
          ? previous - viewportDimension
          : 0;
    }
    return super.applyViewportDimension(viewportDimension);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final exact = owner._anchorCorrection();
    if (exact != null) {
      _extentCorrection = exact;
      _viewportCorrection = 0;
      if (exact.abs() > precisionErrorTolerance) correctBy(0);
    }
    final accepted = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    if (accepted) {
      _inLayout = false;
      owner._scheduleSnapshot(this);
    }
    return accepted;
  }

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    final correction = _extentCorrection + _viewportCorrection;
    _extentCorrection = 0;
    _viewportCorrection = 0;
    if (correction.abs() <= precisionErrorTolerance || oldPosition.outOfRange) {
      return super.correctForNewDimensions(oldPosition, newPosition);
    }
    final adjusted = (newPosition.pixels + correction).clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
    if ((adjusted - newPosition.pixels).abs() <= precisionErrorTolerance) {
      return super.correctForNewDimensions(oldPosition, newPosition);
    }
    correctPixels(adjusted);
    return false;
  }
}

/// Wraps a complete SliverList row with its increasing server message ID.
/// Detached rows are retained only through the current layout retries.
final class ChatMessageExtentObserver extends SingleChildRenderObjectWidget {
  const ChatMessageExtentObserver({
    super.key,
    required this.controller,
    required this.messageId,
    required super.child,
  });

  final ChatScrollController controller;
  final int messageId;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderChatMessageExtent(controller, messageId);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderChatMessageExtent).rebind(controller, messageId);
  }
}

final class _RenderChatMessageExtent extends RenderProxyBox {
  _RenderChatMessageExtent(this.controller, this.messageId);

  ChatScrollController controller;
  int messageId;

  void rebind(ChatScrollController next, int id) {
    if (identical(next, controller) && id == messageId) return;
    if (attached) controller._detach(messageId, this);
    controller = next;
    messageId = id;
    if (attached) controller._attach(messageId, this);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    controller._attach(messageId, this);
  }

  @override
  void detach() {
    controller._detach(messageId, this);
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    RenderObject? sliver = parent;
    while (sliver != null && sliver is! RenderSliver) {
      sliver = sliver.parent;
    }
    final growsTowardHistory =
        sliver is RenderSliver &&
        applyGrowthDirectionToAxisDirection(
              sliver.constraints.axisDirection,
              sliver.constraints.growthDirection,
            ) ==
            AxisDirection.up;
    controller._measured(messageId, this, size.height, growsTowardHistory);
  }
}
