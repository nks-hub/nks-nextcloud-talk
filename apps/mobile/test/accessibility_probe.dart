import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared accessibility probes, so an audit can be run against a screen where
/// its own suite already has a working harness.
///
/// The older audit lived in one file and could only reach screens cheap enough
/// to build twice. Settings, diagnostics and room details each need a
/// database, a mocked server and provider overrides; rebuilding that just to
/// audit them is how an audit ends up covering only the easy screens. These
/// helpers are imported by the suites that already own those harnesses.
///
/// Everything here reads the semantics tree, not the widgets. The first
/// version of the audit asked `IconButton.tooltip` instead, which happens to
/// work for the one way this app names its buttons and would have reported a
/// `Semantics` wrapper or an icon's `semanticLabel` as a failure. Reading the
/// tree also catches the reverse mistake — a named widget whose node never
/// reaches the platform because something excluded it.

/// One labelled node as an assistive technology sees it.
///
/// [ownsName] marks a node whose name is its own rather than a summary of
/// named children — a group such as "conversation filters" spans the whole
/// column it wraps, so keeping it would put every column into one.
typedef AuditedNode = ({
  Rect rect,
  String name,
  bool ownsName,
  bool isButton,
  bool isLive,
});

/// Every node an assistive technology would announce, in traversal order —
/// the order a screen reader moves through the screen.
List<AuditedNode> auditedNodes(WidgetTester tester) {
  final nodes = <AuditedNode>[];
  bool walk(SemanticsNode node, Matrix4 transform) {
    final combined = transform.multiplied(node.transform ?? Matrix4.identity());
    final data = node.getSemanticsData();
    final name = _spokenName(data);
    final slot = nodes.length;
    final named = name.isNotEmpty || data.flagsCollection.isButton;
    if (named) {
      nodes.add((
        rect: MatrixUtils.transformRect(combined, node.rect),
        name: name,
        ownsName: true,
        isButton: data.flagsCollection.isButton,
        isLive: data.flagsCollection.isLiveRegion,
      ));
    }
    var descendantNamed = false;
    for (final child in node.debugListChildrenInOrder(
      DebugSemanticsDumpOrder.traversalOrder,
    )) {
      descendantNamed = walk(child, combined) || descendantNamed;
    }
    if (named && descendantNamed) {
      nodes[slot] = (
        rect: nodes[slot].rect,
        name: nodes[slot].name,
        ownsName: false,
        isButton: nodes[slot].isButton,
        isLive: nodes[slot].isLive,
      );
    }
    return named || descendantNamed;
  }

  // getSemantics on the app element walks up to the node that owns it, which
  // is the root of the tree the platform is handed.
  var root = tester.getSemantics(find.byType(WidgetsApp));
  while (root.parent != null) {
    root = root.parent!;
  }
  walk(root, Matrix4.identity());
  return nodes;
}

/// What the reader actually says for a control.
///
/// `label` is the usual place, but a Material button named through `tooltip`
/// puts it in [SemanticsData.tooltip] instead, and both TalkBack and VoiceOver
/// speak it. Treating only `label` as a name would have reported every
/// tooltip-named button in this app as unnamed.
String _spokenName(SemanticsData data) {
  final label = data.label.trim();
  if (label.isNotEmpty) {
    return label;
  }
  return data.tooltip.trim();
}

/// Controls a screen reader would announce as just "button".
List<Rect> unnamedButtons(WidgetTester tester) => auditedNodes(tester)
    .where((node) => node.isButton && node.name.isEmpty)
    .map((node) => node.rect)
    .toList(growable: false);

/// Requires every control on the pumped screen to say what it does.
///
/// Also requires the screen to have at least one control: a screen without any
/// would satisfy the assertion while proving nothing, which is how the
/// onboarding case was dropped from the original audit.
void expectEveryButtonNamed(WidgetTester tester, {required String screen}) {
  final nodes = auditedNodes(tester);
  expect(
    nodes.where((node) => node.isButton),
    isNotEmpty,
    reason: '$screen has no control at all, so this audit proves nothing',
  );
  expect(unnamedButtons(tester), isEmpty, reason: screen);
}

/// The spoken names in traversal order.
List<String> semanticsReadingOrder(WidgetTester tester) => auditedNodes(tester)
    .where((node) => node.name.isNotEmpty)
    .map((node) => node.name)
    .toList(growable: false);

/// Requires a screen reader never to move back up inside a column.
///
/// Ordering the whole screen top to bottom is the wrong model and was tried
/// first: on the two-column workspace it demanded that the account rail's
/// bottom entries be read between the conversation list's filters and its
/// contents. Reading one column out before moving to the next is what a
/// screen reader user expects, and Flutter does it — so the property worth
/// asserting is the one inside a column: a reader that has moved down must
/// not jump back up. A wrong sort key or content stacked out of position
/// breaks exactly that.
void expectReadingOrderFollowsLayout(
  WidgetTester tester, {
  required String screen,
}) {
  final leaves = auditedNodes(
    tester,
  ).where((node) => node.ownsName && node.name.isNotEmpty).toList();
  expect(
    leaves,
    isNotEmpty,
    reason: '$screen announced nothing, so the order proves nothing',
  );

  // Two entries belong to the same column when their horizontal extents
  // overlap; the columns fall out of the layout instead of being named here.
  final columns = <({double left, double right, List<AuditedNode> members})>[];
  for (final leaf in leaves) {
    final hit = columns.indexWhere(
      (column) =>
          leaf.rect.left < column.right && leaf.rect.right > column.left,
    );
    if (hit < 0) {
      columns.add((
        left: leaf.rect.left,
        right: leaf.rect.right,
        members: [leaf],
      ));
      continue;
    }
    columns[hit] = (
      left: columns[hit].left < leaf.rect.left
          ? columns[hit].left
          : leaf.rect.left,
      right: columns[hit].right > leaf.rect.right
          ? columns[hit].right
          : leaf.rect.right,
      members: columns[hit].members..add(leaf),
    );
  }

  // A row of controls sits at the same height, so only a clear vertical step
  // counts as moving; the band scales with the device pixel ratio because
  // node rectangles arrive in physical pixels.
  final band = 8 * tester.view.devicePixelRatio;
  for (final column in columns) {
    var lowest = double.negativeInfinity;
    String? previous;
    for (final member in column.members) {
      expect(
        member.rect.top,
        greaterThanOrEqualTo(lowest - band),
        reason:
            '$screen: "${member.name}" is read after "$previous" but sits '
            'above it in the same column',
      );
      if (member.rect.top > lowest) {
        lowest = member.rect.top;
        previous = member.name;
      }
    }
  }
}

/// Requires exactly the announcement regions a screen is supposed to have.
///
/// A live region is what makes an arriving message speak without the user
/// moving focus. Two of them on one screen is as wrong as none: the reader
/// interrupts itself.
void expectLiveRegions(
  WidgetTester tester, {
  required String screen,
  required int count,
}) {
  expect(
    auditedNodes(tester).where((node) => node.isLive).length,
    count,
    reason: '$screen live regions',
  );
}

/// A small phone at double text — the tightest combination the app ships for.
void useTightPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Runs [body] and returns every overflow Flutter reported while painting.
///
/// Overflow is a state the render object discovers while painting and keeps in
/// a private field, so neither `debugNeedsLayout` nor a finished pump exposes
/// it; the only honest way to see it is to catch the complaint.
Future<List<String>> overflowsWhile(Future<void> Function() body) async {
  final overflows = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    final message = details.exceptionAsString();
    if (message.contains('overflowed')) {
      overflows.add(message.split('\n').first);
      return;
    }
    previous?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return overflows;
}
