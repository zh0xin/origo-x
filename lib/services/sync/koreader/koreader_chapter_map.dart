// 文件说明：章节「拍平偏移 ↔ EPUB DOM 节点」关联层。
// 技术要点：镜像 epub_native_parser_io.dart 里 _collectInlineContent 的拍平规则
//（\s+|\S+ 折叠、pendingSpace/trailingNewlines、块边界注入 \n/\n\n、<br>→\n、
// pre 保留、首尾 trim），在产出与 App 完全一致的 plainText 的同时，为每个 UTF-16
// 码元记录它来自哪个 DOM 文本节点、节点内的原始偏移。有了这张出处表，就能：
//   拍平偏移 → (文本节点, 原始偏移) → KoreaderXPointer（推送给 KOReader）
//   KOReader XPointer → (文本节点, 原始偏移) → 拍平偏移（拉取并跳转）
//
// ⚠️ 与主解析器**并行独立**：只在同步时对单章 XHTML 重解析，不改热路径。
// 由 test/koreader_xpointer_oracle_test.dart 用真实 EPUB + crengine 真值校验。

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'koreader_xpointer.dart';

/// 与 epub_native_parser_io.dart `_textBlockTags` 保持一致。
const Set<String> _textBlockTags = <String>{
  'address',
  'article',
  'blockquote',
  'dd',
  'div',
  'dt',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'p',
  'pre',
  'section',
  'stanza',
  'subtitle',
  'v',
};

bool _isAllWhitespace(String s) => RegExp(r'^\s+$').hasMatch(s);

/// 单个拍平码元的出处：来自 [node] 的第 [rawOffset] 个码元；注入字符为 null。
class _Provenance {
  const _Provenance(this.node, this.rawOffset);
  final dom.Text node;
  final int rawOffset;
}

class KoreaderChapterMap {
  KoreaderChapterMap._(
    this.document,
    this.xpointer,
    this._plainText,
    this._prov,
  );

  final dom.Document document;
  final KoreaderXPointer xpointer;
  final String _plainText;
  final List<_Provenance?> _prov;

  /// 与 App 章节 plainText 对齐的拍平文本。
  String get plainText => _plainText;

  /// 解析单章 XHTML，构建关联层。[spineIndex] 为 0 基书脊序号。
  factory KoreaderChapterMap.parse(String xhtml, {required int spineIndex}) {
    final document = html_parser.parse(xhtml);
    final body = document.body;
    final builder = _Walker();
    if (body != null) builder.visit(body, body.localName == 'pre');
    final trimmed = builder.finish();
    return KoreaderChapterMap._(
      document,
      KoreaderXPointer(document, spineIndex: spineIndex),
      trimmed.text,
      trimmed.prov,
    );
  }

  /// 拍平偏移 → KOReader XPointer（注入字符处向后就近吸附到真实字符）。
  String? xpointerForOffset(int flatOffset) {
    var i = flatOffset.clamp(0, _prov.length);
    for (; i < _prov.length; i++) {
      final p = _prov[i];
      if (p != null) return xpointer.forTextNode(p.node, p.rawOffset);
    }
    for (var j = flatOffset - 1; j >= 0; j--) {
      final p = _prov[j];
      if (p != null) return xpointer.forTextNode(p.node, p.rawOffset);
    }
    return null;
  }

  /// KOReader XPointer → 拍平偏移（就近吸附到该文本节点内 >= 目标原始偏移的字符）。
  int? offsetForXPointer(String xp) {
    final point = xpointer.resolve(xp);
    if (point == null) return null;
    final node = point.textNode;
    final rawOffset = point.rawOffset;
    if (node == null || rawOffset == null) {
      // 只定位到元素：吸附到该元素子树内第一个有出处的拍平字符。
      return _firstOffsetInElement(point.element);
    }
    var best = -1;
    var bestRaw = 1 << 30;
    for (var i = 0; i < _prov.length; i++) {
      final p = _prov[i];
      if (p == null || !identical(p.node, node)) continue;
      if (p.rawOffset >= rawOffset && p.rawOffset < bestRaw) {
        best = i;
        bestRaw = p.rawOffset;
        if (p.rawOffset == rawOffset) break;
      }
    }
    if (best >= 0) return best;
    // 落在节点末尾：取该节点最后一个出现的拍平字符 + 1。
    for (var i = _prov.length - 1; i >= 0; i--) {
      final p = _prov[i];
      if (p != null && identical(p.node, node)) return i + 1;
    }
    return null;
  }

  int? _firstOffsetInElement(dom.Element element) {
    for (var i = 0; i < _prov.length; i++) {
      final p = _prov[i];
      if (p == null) continue;
      for (dom.Node? n = p.node; n != null; n = n.parent) {
        if (identical(n, element)) return i;
      }
    }
    return null;
  }
}

/// 拍平结果：文本 + 逐码元出处。
class _WalkResult {
  _WalkResult(this.text, this.prov);
  final String text;
  final List<_Provenance?> prov;
}

/// 镜像 _collectInlineContent 的深度优先走查器。
class _Walker {
  final StringBuffer _out = StringBuffer();
  final List<_Provenance?> _prov = <_Provenance?>[];
  bool _pendingSpace = false;
  int _trailingNewlines = 0;

  void _append(String text, {dom.Text? node, int nodeStart = 0}) {
    if (text.isEmpty) return;
    for (var k = 0; k < text.length; k++) {
      _prov.add(node == null ? null : _Provenance(node, nodeStart + k));
    }
    _out.write(text);
    // 重算尾部连续换行数。
    var n = 0;
    for (var i = text.length - 1; i >= 0; i--) {
      if (text.codeUnitAt(i) == 0x0a) {
        n++;
      } else {
        _trailingNewlines = n;
        return;
      }
    }
    _trailingNewlines += n;
  }

  void _appendText(String value, dom.Text node, {required bool preformatted}) {
    if (preformatted) {
      // CRLF/CR → \n，同时把每个码元映回 node.data 的原始下标。
      for (var i = 0; i < value.length; i++) {
        final c = value.codeUnitAt(i);
        if (c == 0x0d) {
          _append('\n', node: node, nodeStart: i);
          if (i + 1 < value.length && value.codeUnitAt(i + 1) == 0x0a) i++;
        } else {
          _append(value[i], node: node, nodeStart: i);
        }
      }
      _pendingSpace = false;
      return;
    }
    for (final m in RegExp(r'\s+|\S+').allMatches(value)) {
      final token = m.group(0)!;
      if (_isAllWhitespace(token)) {
        if (_out.isNotEmpty) _pendingSpace = true;
      } else {
        if (_pendingSpace && _out.isNotEmpty && _trailingNewlines == 0) {
          _append(' ');
        }
        _pendingSpace = false;
        _append(token, node: node, nodeStart: m.start);
      }
    }
  }

  void _appendParagraphBoundary() {
    if (_out.isEmpty) return;
    if (_trailingNewlines >= 2) return;
    _append(_trailingNewlines == 1 ? '\n' : '\n\n');
    _pendingSpace = false;
  }

  void visit(dom.Element node, bool preformatted) {
    for (final child in node.nodes) {
      if (child is dom.Text) {
        _appendText(child.data, child, preformatted: preformatted);
        continue;
      }
      if (child is! dom.Element) continue;
      final tag = child.localName?.toLowerCase() ?? '';
      if (tag == 'script' || tag == 'style' || tag == 'head') continue;
      if (tag == 'br') {
        _append('\n');
        _pendingSpace = false;
        continue;
      }
      if (tag == 'img' || tag == 'image') continue; // 零长度，不产字符
      final isBlock = _textBlockTags.contains(tag);
      if (isBlock) _appendParagraphBoundary();
      visit(child, preformatted || tag == 'pre');
      if (isBlock) _appendParagraphBoundary();
    }
  }

  _WalkResult finish() {
    // 与 _collectInlineContent 的收尾一致：用 String.trimLeft/trimRight 去除首尾
    // 空白（Unicode 语义），并同步裁剪出处表，保证 plainText 与偏移逐码元对齐。
    final text = _out.toString();
    final leading = text.length - text.trimLeft().length;
    final trailing = text.length - text.trimRight().length;
    final end = text.length - trailing;
    if (leading >= end) {
      return _WalkResult('', const <_Provenance?>[]);
    }
    return _WalkResult(
      text.substring(leading, end),
      _prov.sublist(leading, end),
    );
  }
}
