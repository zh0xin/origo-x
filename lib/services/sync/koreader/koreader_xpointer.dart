// 文件说明：KOReader（CREngine）XPointer 生成与解析。
// 技术要点：把 CREngine 构建 EPUB DOM 的关键归一化规则复刻到 Dart（空白折叠、
// 块首纯空白文本节点丢弃、文本节点编号、pre/code 保留空白、cfi-skip/cfi-inert
// 包裹元素透明化），使得同一段文本能命中 KOReader 落点的同一个字符。
//
// 覆盖 open-reading 真正需要的两个方向——
//   1) 给定 (文本节点, 原始偏移) → 生成 XPointer；
//   2) 给定 XPointer → 解析回 (文本节点, 原始偏移)。
// 不含 CFI 侧逻辑（open-reading 没有 CFI）。规则严格对齐 readest 的 xcfi.ts，
// 并由 test/koreader_xpointer_test.dart 用 readest/CREngine 的真值向量校验。

import 'package:html/dom.dart' as dom;

/// CREngine 视为 `white-space: pre`（保留空白、不折叠）的标签。
const Set<String> _preTags = <String>{
  'pre',
  'code',
  'listing',
  'plaintext',
  'xmp',
  'textarea',
};

/// CREngine 视为块级、会在开头丢弃纯空白文本节点的标签。
const Set<String> _blockTags = <String>{
  'body',
  'div',
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'ul',
  'ol',
  'li',
  'dl',
  'dt',
  'dd',
  'blockquote',
  'pre',
  'section',
  'article',
  'aside',
  'header',
  'footer',
  'nav',
  'main',
  'figure',
  'figcaption',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'td',
  'th',
  'caption',
  'address',
  'details',
  'summary',
  'form',
  'fieldset',
  'center',
};

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 || // space
    codeUnit == 0x09 || // tab
    codeUnit == 0x0a || // LF
    codeUnit == 0x0d || // CR
    codeUnit == 0x0c; // FF

/// XPointer 解析结果：元素 + 可选的精确文本点（节点 + 原始偏移）。
class KoreaderXPointerPoint {
  const KoreaderXPointerPoint({
    required this.element,
    this.textNode,
    this.rawOffset,
  });

  final dom.Element element;
  final dom.Text? textNode;
  final int? rawOffset;
}

class KoreaderXPointer {
  KoreaderXPointer(this.document, {required this.spineIndex});

  final dom.Document document;
  final int spineIndex;

  dom.Element get _root => document.documentElement!;

  // ------------------------------------------------------------ 空白折叠

  static bool _isRunContinuation(String text, int i) =>
      i > 0 &&
      _isWhitespace(text.codeUnitAt(i)) &&
      _isWhitespace(text.codeUnitAt(i - 1));

  /// 原始 DOM 偏移 → CREngine 折叠偏移（连续空白算 1）。
  static int toCollapsedOffset(String text, int rawOffset) {
    var collapsed = 0;
    for (var i = 0; i < rawOffset && i < text.length; i++) {
      if (!_isRunContinuation(text, i)) collapsed++;
    }
    final overshoot = rawOffset - text.length;
    return collapsed + (overshoot > 0 ? overshoot : 0);
  }

  /// CREngine 折叠偏移 → 原始 DOM 偏移。
  static int toRawOffset(String text, int collapsedOffset) {
    var collapsed = 0;
    for (var i = 0; i < text.length; i++) {
      if (_isRunContinuation(text, i)) continue;
      if (collapsed == collapsedOffset) return i;
      collapsed++;
    }
    return text.length;
  }

  static bool _preservesWhitespace(dom.Node node) {
    dom.Element? el = node is dom.Element ? node.parent : node.parent;
    for (; el != null; el = el.parent) {
      if (_preTags.contains(el.localName?.toLowerCase())) return true;
    }
    return false;
  }

  static int _crengineOffset(dom.Text node, int rawOffset) {
    if (_preservesWhitespace(node)) return rawOffset;
    return toCollapsedOffset(node.data, rawOffset);
  }

  static int _nodeOffset(dom.Text node, int crengineOffset) {
    if (_preservesWhitespace(node)) {
      return crengineOffset < node.data.length
          ? crengineOffset
          : node.data.length;
    }
    return toRawOffset(node.data, crengineOffset);
  }

  // ------------------------------------------------------------ 文本子节点

  /// CREngine 保留的直接文本子节点：非空；块级元素开头的纯空白节点被丢弃。
  static List<dom.Text> crengineTextChildren(dom.Element element) {
    final first = element.nodes.isNotEmpty ? element.nodes.first : element;
    final dropsLeadingBlank =
        _blockTags.contains(element.localName?.toLowerCase()) &&
        !_preservesWhitespace(first);
    final result = <dom.Text>[];
    final nodes = element.nodes;
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is! dom.Text) continue;
      final text = node.data;
      if (text.isEmpty) continue;
      if (dropsLeadingBlank && i == 0 && text.trim().isEmpty) continue;
      result.add(node);
    }
    return result;
  }

  // ------------------------------------------------------------ 包裹元素透明化

  static bool _isCfiInert(dom.Element element) =>
      element.attributes.containsKey('cfi-inert');

  static bool _isCfiSkip(dom.Element element) =>
      element.attributes.containsKey('cfi-skip');

  List<dom.Element> _effectiveChildren(dom.Element parent) {
    final result = <dom.Element>[];
    for (final child in parent.children) {
      if (_isCfiInert(child)) continue;
      if (_isCfiSkip(child)) {
        result.addAll(_effectiveChildren(child));
      } else {
        result.add(child);
      }
    }
    return result;
  }

  static dom.Element _skipTransparentParent(dom.Element element) {
    var el = element;
    while (_isCfiSkip(el) && el.parent != null) {
      el = el.parent!;
    }
    return el;
  }

  // ------------------------------------------------------------ 路径构建（生成）

  String buildXPointerPath(dom.Element target) {
    final pathParts = <String>[];
    dom.Element? current = target;

    while (current != null && current != _root) {
      if (_isCfiSkip(current)) {
        current = current.parent;
        continue;
      }
      final parent = current.parent;
      if (parent == null) break;

      final tagName = current.localName!.toLowerCase();
      final siblings = _effectiveChildren(_skipTransparentParent(parent));
      var siblingIndex = 0;
      var sameTag = 0;
      for (final sibling in siblings) {
        if (sibling.localName?.toLowerCase() == tagName) {
          if (identical(sibling, current)) siblingIndex = sameTag;
          sameTag++;
        }
      }
      pathParts.insert(
        0,
        sameTag == 1 ? tagName : '$tagName[${siblingIndex + 1}]',
      );
      current = parent;
    }

    var xpointer = '/body/DocFragment[${spineIndex + 1}]';
    if (pathParts.isNotEmpty && pathParts.first.startsWith('body')) {
      pathParts.removeAt(0);
    }
    xpointer += '/body';
    if (pathParts.isNotEmpty) xpointer += '/${pathParts.join('/')}';
    return xpointer;
  }

  /// 给定文本节点内的原始偏移，生成 KOReader XPointer。
  String forTextNode(dom.Text node, int rawOffset) {
    final parent = node.parent ?? _root;
    final basePath = buildXPointerPath(parent);
    final siblings = crengineTextChildren(parent);
    final index = siblings.indexWhere((t) => identical(t, node));
    // 被丢弃的块首空白锚定到块开头（裸元素路径）。
    if (index < 0) return basePath;
    final collapsed = _crengineOffset(node, rawOffset);
    if (siblings.length <= 1) return '$basePath/text().$collapsed';
    return '$basePath/text()[${index + 1}].$collapsed';
  }

  // ------------------------------------------------------------ 解析

  /// 解析 XPointer，返回精确文本点。无法定位元素时返回 null。
  KoreaderXPointerPoint? resolve(String xpointer) {
    // /text()[K].N
    final indexed = RegExp(r'/text\(\)\[(\d+)\]\.(\d+)$').firstMatch(xpointer);
    if (indexed != null) {
      final k = int.parse(indexed.group(1)!);
      final collapsed = int.parse(indexed.group(2)!);
      final path = xpointer.replaceFirst(RegExp(r'/text\(\)\[\d+\]\.\d+$'), '');
      final element = _resolvePath(path);
      if (element == null) return null;
      final children = crengineTextChildren(element);
      if (k - 1 < 0 || k - 1 >= children.length) {
        return KoreaderXPointerPoint(element: element);
      }
      final node = children[k - 1];
      return KoreaderXPointerPoint(
        element: element,
        textNode: node,
        rawOffset: _nodeOffset(node, collapsed),
      );
    }

    // /text().N
    final sole = RegExp(r'/text\(\)\.(\d+)$').firstMatch(xpointer);
    if (sole != null) {
      final collapsed = int.parse(sole.group(1)!);
      final path = xpointer.replaceFirst(RegExp(r'/text\(\)\.\d+$'), '');
      final element = _resolvePath(path);
      if (element == null) return null;
      final children = crengineTextChildren(element);
      final node = children.firstWhere(
        (t) => t.data.trim().isNotEmpty,
        orElse: () => children.isNotEmpty ? children.first : dom.Text(''),
      );
      if (node.data.isEmpty && children.isEmpty) {
        return KoreaderXPointerPoint(element: element);
      }
      return KoreaderXPointerPoint(
        element: element,
        textNode: node,
        rawOffset: _nodeOffset(node, collapsed),
      );
    }

    // /tag[idx].N —— 偏移直接落在元素上（KOReader 在元素文本起点常见此形）。
    final elementOffset = RegExp(
      r'^(.*/\w+(?:\[\d+\])?)\.(\d+)$',
    ).firstMatch(xpointer);
    if (elementOffset != null) {
      final path = elementOffset.group(1)!;
      final collapsed = int.parse(elementOffset.group(2)!);
      final element = _resolvePath(path);
      if (element == null) return null;
      final children = crengineTextChildren(element);
      if (children.isEmpty) return KoreaderXPointerPoint(element: element);
      final node = children.first;
      return KoreaderXPointerPoint(
        element: element,
        textNode: node,
        rawOffset: _nodeOffset(node, collapsed),
      );
    }

    final element = _resolvePath(xpointer);
    if (element == null) return null;
    return KoreaderXPointerPoint(element: element);
  }

  /// 解析形如 /body/DocFragment[N]/body/div/p[1] 的元素路径到具体元素。
  dom.Element? _resolvePath(String path) {
    final stripped = path.replaceFirst(
      RegExp(r'^/body/DocFragment(?:\[\d+\])?/body'),
      '',
    );
    var el = document.body;
    if (el == null) return null;
    if (stripped.isEmpty) return el;
    for (final segment in stripped.split('/')) {
      if (segment.isEmpty) continue;
      final match = RegExp(r'^(\w+)(?:\[(\d+)\])?$').firstMatch(segment);
      if (match == null) return null;
      final tag = match.group(1)!.toLowerCase();
      final k = match.group(2) != null ? int.parse(match.group(2)!) : 1;
      final candidates = _effectiveChildren(
        el!,
      ).where((e) => e.localName?.toLowerCase() == tag).toList();
      if (k - 1 < 0 || k - 1 >= candidates.length) return null;
      el = candidates[k - 1];
    }
    return el;
  }
}
