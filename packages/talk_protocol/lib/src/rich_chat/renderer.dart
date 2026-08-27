import 'package:markdown/markdown.dart' as markdown;

import '../chat/models.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const int _maximumRenderMessageCharacters = 1024 * 1024;
const int _maximumRenderParameters = 10000;
const int _maximumRenderNodes = 200000;
const int _maximumRenderDepth = 64;
final RegExp _placeholderPattern = RegExp(r'\{([A-Za-z0-9_.-]+)\}');
final RegExp _textTokenPattern = RegExp(r'\{([A-Za-z0-9_.-]+)\}|\n');

enum RichChatSemanticKind {
  document,
  paragraph,
  heading,
  text,
  emphasis,
  strong,
  strikethrough,
  inlineCode,
  codeBlock,
  unorderedList,
  orderedList,
  taskList,
  listItem,
  taskCheckbox,
  quote,
  table,
  tableSection,
  tableRow,
  tableCell,
  link,
  richObject,
  softBreak,
  horizontalRule,
}

enum RichChatObjectKind {
  user,
  guest,
  email,
  userGroup,
  circle,
  call,
  federatedUser,
  generic,
}

/// One immutable node in the renderer-neutral rich-chat semantic tree.
final class RichChatSemanticNode {
  RichChatSemanticNode._({
    required this.kind,
    required Iterable<RichChatSemanticNode> children,
    required this.text,
    required this.link,
    required this.parameterKey,
    required this.parameter,
    required this.objectKind,
    required this.headingLevel,
    required this.orderedStart,
    required this.checked,
  }) : children = List.unmodifiable(children);

  factory RichChatSemanticNode.element(
    RichChatSemanticKind kind,
    Iterable<RichChatSemanticNode> children, {
    int? headingLevel,
    int? orderedStart,
    bool? checked,
  }) => RichChatSemanticNode._(
    kind: kind,
    children: children,
    text: null,
    link: null,
    parameterKey: null,
    parameter: null,
    objectKind: null,
    headingLevel: headingLevel,
    orderedStart: orderedStart,
    checked: checked,
  );

  factory RichChatSemanticNode.text(String text) => RichChatSemanticNode._(
    kind: RichChatSemanticKind.text,
    children: const [],
    text: text,
    link: null,
    parameterKey: null,
    parameter: null,
    objectKind: null,
    headingLevel: null,
    orderedStart: null,
    checked: null,
  );

  factory RichChatSemanticNode.code(RichChatSemanticKind kind, String text) =>
      RichChatSemanticNode._(
        kind: kind,
        children: const [],
        text: text,
        link: null,
        parameterKey: null,
        parameter: null,
        objectKind: null,
        headingLevel: null,
        orderedStart: null,
        checked: null,
      );

  factory RichChatSemanticNode.link(
    String link,
    Iterable<RichChatSemanticNode> children,
  ) => RichChatSemanticNode._(
    kind: RichChatSemanticKind.link,
    children: children,
    text: null,
    link: link,
    parameterKey: null,
    parameter: null,
    objectKind: null,
    headingLevel: null,
    orderedStart: null,
    checked: null,
  );

  factory RichChatSemanticNode.richObject(
    String parameterKey,
    ChatRichObjectParameter parameter,
  ) => RichChatSemanticNode._(
    kind: RichChatSemanticKind.richObject,
    children: const [],
    text: null,
    link: null,
    parameterKey: parameterKey,
    parameter: parameter,
    objectKind: _objectKind(parameter.type),
    headingLevel: null,
    orderedStart: null,
    checked: null,
  );

  factory RichChatSemanticNode.softBreak() => RichChatSemanticNode._(
    kind: RichChatSemanticKind.softBreak,
    children: const [],
    text: '\n',
    link: null,
    parameterKey: null,
    parameter: null,
    objectKind: null,
    headingLevel: null,
    orderedStart: null,
    checked: null,
  );

  final RichChatSemanticKind kind;
  final List<RichChatSemanticNode> children;
  final String? text;
  final String? link;
  final String? parameterKey;
  final ChatRichObjectParameter? parameter;
  final RichChatObjectKind? objectKind;
  final int? headingLevel;
  final int? orderedStart;
  final bool? checked;

  Iterable<RichChatSemanticNode> get depthFirst sync* {
    yield this;
    for (final child in children) {
      yield* child.depthFirst;
    }
  }

  String get flattenedText {
    if (kind == RichChatSemanticKind.richObject) {
      return parameter?.name ?? parameter?.id ?? '';
    }
    if (text != null) {
      return text!;
    }
    return children.map((child) => child.flattenedText).join();
  }

  @override
  String toString() =>
      'RichChatSemanticNode(kind: ${kind.name}, content: <redacted>)';
}

final class RichChatDocument {
  RichChatDocument._(Iterable<RichChatSemanticNode> children)
    : root = RichChatSemanticNode.element(
        RichChatSemanticKind.document,
        children,
      ) {
    final nodes = root.depthFirst.toList(growable: false);
    if (nodes.length > _maximumRenderNodes) {
      _renderFailure(r'$.message');
    }
    nodeCount = nodes.length;
    activeLinks = List.unmodifiable(
      nodes
          .where((node) => node.kind == RichChatSemanticKind.link)
          .map((node) => node.link!)
          .toList(growable: false),
    );
  }

  final RichChatSemanticNode root;
  late final int nodeCount;
  late final List<String> activeLinks;

  Iterable<RichChatSemanticNode> get nodes => root.depthFirst;

  @override
  String toString() =>
      'RichChatDocument(nodeCount: $nodeCount, content: <redacted>)';
}

RichChatDocument renderRichChatMessage({
  required String message,
  required bool markdownEnabled,
  required Map<String, ChatRichObjectParameter> parameters,
  required ServerBase server,
}) {
  if (message.length > _maximumRenderMessageCharacters ||
      parameters.length > _maximumRenderParameters) {
    _renderFailure(r'$.message');
  }
  for (final key in parameters.keys) {
    if (!_placeholderPattern.hasMatch('{$key}') ||
        _placeholderPattern.firstMatch('{$key}')?.group(0) != '{$key}') {
      _renderFailure(r'$.messageParameters');
    }
  }

  final budget = _RenderBudget();
  if (!markdownEnabled) {
    return RichChatDocument._(_textNodes(message, parameters, budget));
  }

  final document = markdown.Document(
    extensionSet: markdown.ExtensionSet.gitHubWeb,
    encodeHtml: true,
  );
  final ast = document.parse(message);
  final nodes = <RichChatSemanticNode>[];
  for (final node in ast) {
    nodes.addAll(
      _convertNode(
        node,
        parameters: parameters,
        server: server,
        budget: budget,
        depth: 0,
      ),
    );
  }
  return RichChatDocument._(nodes);
}

List<RichChatSemanticNode> _convertNode(
  markdown.Node node, {
  required Map<String, ChatRichObjectParameter> parameters,
  required ServerBase server,
  required _RenderBudget budget,
  required int depth,
}) {
  budget.requireDepth(depth);
  if (node is markdown.Text) {
    return _textNodes(
      _unescapeMarkdownText(node.text),
      parameters,
      budget,
    );
  }
  if (node is! markdown.Element) {
    return _textNodes(
      _unescapeMarkdownText(node.textContent),
      parameters,
      budget,
    );
  }

  if (node.tag == 'pre') {
    return _singleNode(
      budget,
      () => RichChatSemanticNode.code(
        RichChatSemanticKind.codeBlock,
        node.textContent,
      ),
    );
  }
  if (node.tag == 'code') {
    return _singleNode(
      budget,
      () => RichChatSemanticNode.code(
        RichChatSemanticKind.inlineCode,
        node.textContent,
      ),
    );
  }
  if (node.tag == 'br') {
    return _singleNode(budget, RichChatSemanticNode.softBreak);
  }
  if (node.tag == 'hr') {
    return _singleNode(
      budget,
      () => RichChatSemanticNode.element(
        RichChatSemanticKind.horizontalRule,
        const [],
      ),
    );
  }
  if (node.tag == 'input' && node.attributes['type'] == 'checkbox') {
    return _singleNode(
      budget,
      () => RichChatSemanticNode.element(
        RichChatSemanticKind.taskCheckbox,
        const [],
        checked: node.attributes['checked'] == 'true',
      ),
    );
  }

  final convertedChildren = <RichChatSemanticNode>[];
  for (final child in node.children ?? const <markdown.Node>[]) {
    convertedChildren.addAll(
      _convertNode(
        child,
        parameters: parameters,
        server: server,
        budget: budget,
        depth: depth + 1,
      ),
    );
  }
  if (node.tag == 'a') {
    final safe = _safeLink(node.attributes['href'], server);
    if (safe == null) {
      return convertedChildren;
    }
    return _singleNode(
      budget,
      () => RichChatSemanticNode.link(safe, convertedChildren),
    );
  }

  final kind = switch (node.tag) {
    'p' => RichChatSemanticKind.paragraph,
    'em' => RichChatSemanticKind.emphasis,
    'strong' => RichChatSemanticKind.strong,
    'del' => RichChatSemanticKind.strikethrough,
    'ul' when node.attributes['class'] == 'contains-task-list' =>
      RichChatSemanticKind.taskList,
    'ul' => RichChatSemanticKind.unorderedList,
    'ol' when node.attributes['class'] == 'contains-task-list' =>
      RichChatSemanticKind.taskList,
    'ol' => RichChatSemanticKind.orderedList,
    'li' => RichChatSemanticKind.listItem,
    'blockquote' => RichChatSemanticKind.quote,
    'table' => RichChatSemanticKind.table,
    'thead' || 'tbody' => RichChatSemanticKind.tableSection,
    'tr' => RichChatSemanticKind.tableRow,
    'th' || 'td' => RichChatSemanticKind.tableCell,
    _ => null,
  };
  final headingLevel = _headingLevel(node.tag);
  if (headingLevel != null) {
    return _singleNode(
      budget,
      () => RichChatSemanticNode.element(
        RichChatSemanticKind.heading,
        convertedChildren,
        headingLevel: headingLevel,
      ),
    );
  }
  if (kind == null) {
    return _textNodes(
      _unescapeMarkdownText(node.textContent),
      parameters,
      budget,
    );
  }
  return _singleNode(
    budget,
    () => RichChatSemanticNode.element(
      kind,
      convertedChildren,
      orderedStart: node.tag == 'ol'
          ? int.tryParse(node.attributes['start'] ?? '1')
          : null,
    ),
  );
}

List<RichChatSemanticNode> _singleNode(
  _RenderBudget budget,
  RichChatSemanticNode Function() create,
) => <RichChatSemanticNode>[budget.createNode(create)];

/// Undoes the HTML escaping `package:markdown` applies to text nodes.
///
/// That package produces text destined for an HTML document, so a quote comes
/// back as `&quot;` and an ampersand as `&amp;`. We render plain Flutter text,
/// where those would show literally — which is exactly what a user saw in a
/// message containing quotation marks.
///
/// Only the five entities that package emits are undone, and `&amp;` is undone
/// last so that a message actually containing `&amp;quot;` keeps its text
/// instead of collapsing into a quote.
String _unescapeMarkdownText(String text) {
  if (!text.contains('&')) {
    return text;
  }
  return text
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}

List<RichChatSemanticNode> _textNodes(
  String text,
  Map<String, ChatRichObjectParameter> parameters,
  _RenderBudget budget,
) {
  final result = <RichChatSemanticNode>[];
  void emit(RichChatSemanticNode Function() create) {
    result.add(budget.createNode(create));
  }

  var cursor = 0;
  for (final match in _textTokenPattern.allMatches(text)) {
    if (match.start > cursor) {
      emit(
        () => RichChatSemanticNode.text(text.substring(cursor, match.start)),
      );
    }
    final token = match.group(0)!;
    if (token == '\n') {
      emit(RichChatSemanticNode.softBreak);
    } else {
      final key = match.group(1)!;
      emit(() {
        final parameter = parameters[key];
        return parameter == null
            ? RichChatSemanticNode.text(token)
            : RichChatSemanticNode.richObject(key, parameter);
      });
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    emit(() => RichChatSemanticNode.text(text.substring(cursor)));
  }
  if (result.isEmpty && text.isNotEmpty) {
    emit(() => RichChatSemanticNode.text(text));
  }
  return result;
}

String? _safeLink(String? rawLink, ServerBase server) {
  if (rawLink == null ||
      rawLink.isEmpty ||
      rawLink.contains(r'\') ||
      rawLink.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return null;
  }
  final parsed = Uri.tryParse(rawLink);
  if (parsed == null || parsed.userInfo.isNotEmpty) {
    return null;
  }
  if (parsed.hasScheme) {
    if (!const <String>{
      'https',
      'mailto',
      'tel',
    }.contains(parsed.scheme.toLowerCase())) {
      return null;
    }
    return rawLink;
  }
  final resolved = server.uri.resolveUri(parsed);
  if (!server.hasSameOrigin(resolved)) {
    return null;
  }
  return resolved.toString();
}

int? _headingLevel(String tag) {
  if (tag.length != 2 || tag.codeUnitAt(0) != 0x68) {
    return null;
  }
  final level = int.tryParse(tag.substring(1));
  return level != null && level >= 1 && level <= 6 ? level : null;
}

RichChatObjectKind _objectKind(String type) => switch (type) {
  'user' => RichChatObjectKind.user,
  'guest' => RichChatObjectKind.guest,
  'email' => RichChatObjectKind.email,
  'user-group' => RichChatObjectKind.userGroup,
  'circle' => RichChatObjectKind.circle,
  'call' => RichChatObjectKind.call,
  'federated-user' || 'federated_user' => RichChatObjectKind.federatedUser,
  _ => RichChatObjectKind.generic,
};

final class _RenderBudget {
  int _remainingNodes = _maximumRenderNodes - 1;

  void requireDepth(int depth) {
    if (depth > _maximumRenderDepth) {
      _renderFailure(r'$.message');
    }
  }

  RichChatSemanticNode createNode(RichChatSemanticNode Function() create) {
    if (_remainingNodes == 0) {
      _renderFailure(r'$.message');
    }
    _remainingNodes -= 1;
    return create();
  }
}

Never _renderFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidRichChatRender, path);
