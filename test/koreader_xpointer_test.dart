// 文件说明：KOReader XPointer 原型的真值校验。
// 每个向量的 HTML 与期望 XPointer / 落点均来自 readest 的 xcfi 语义测试与
// CREngine 真值，用来证明 Dart 侧的 CREngine DOM 复刻能字符级对齐。

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/koreader/koreader_xpointer.dart';

dom.Document _parse(String fragment) =>
    html_parser.parse('<html><body>$fragment</body></html>');

/// 按文档顺序取第 [index] 个文本节点（含被 CREngine 丢弃者）。
dom.Text _textNodeAt(dom.Node root, int index) {
  final all = <dom.Text>[];
  void walk(dom.Node n) {
    for (final c in n.nodes) {
      if (c is dom.Text) all.add(c);
      walk(c);
    }
  }

  walk(root);
  return all[index];
}

/// 取元素的第 [index] 个「直接」文本子节点（含被 CREngine 丢弃者）。
dom.Text _directText(dom.Element element, int index) =>
    element.nodes.whereType<dom.Text>().toList()[index];

/// 解析 XPointer 起止两点，取同一文本节点内的原始子串。
String _resolveSpan(KoreaderXPointer xp, String start, String end) {
  final a = xp.resolve(start)!;
  final b = xp.resolve(end)!;
  expect(
    identical(a.textNode, b.textNode),
    isTrue,
    reason: 'span crosses text nodes: $start .. $end',
  );
  return a.textNode!.data.substring(a.rawOffset!, b.rawOffset!);
}

void main() {
  group('toCollapsedOffset / toRawOffset', () {
    test('连续空白折叠为 1', () {
      const text = 'lambda   mu     nu';
      expect(KoreaderXPointer.toCollapsedOffset(text, 9), 7); // 'm' of mu
      expect(KoreaderXPointer.toCollapsedOffset(text, 11), 9); // after mu
      expect(KoreaderXPointer.toRawOffset(text, 7), 9);
      expect(KoreaderXPointer.toRawOffset(text, 9), 11);
    });

    test('往返一致（非空白起点）', () {
      const text = '  a  b  ';
      for (final raw in [2, 5]) {
        final collapsed = KoreaderXPointer.toCollapsedOffset(text, raw);
        expect(KoreaderXPointer.toRawOffset(text, collapsed), raw);
      }
    });
  });

  group('crengineTextChildren', () {
    test('块首纯空白文本节点被丢弃', () {
      final doc = _parse('<p>\n<em>delta</em> epsilon</p>');
      final p = doc.body!.querySelector('p')!;
      final kept = KoreaderXPointer.crengineTextChildren(p);
      // 只保留 " epsilon"（开头的 "\n" 被丢），em 是元素不计。
      expect(kept.length, 1);
      expect(kept.first.data, ' epsilon');
    });

    test('pre 内不丢弃、不折叠', () {
      final doc = _parse('<pre>ab  cd</pre>');
      final pre = doc.body!.querySelector('pre')!;
      final kept = KoreaderXPointer.crengineTextChildren(pre);
      expect(kept.length, 1);
      expect(kept.first.data, 'ab  cd');
    });
  });

  group('forTextNode（生成）', () {
    test('单一文本子节点 → /text().N，偏移折叠', () {
      final doc = _parse('<p>lambda   mu     nu</p>');
      final xp = KoreaderXPointer(doc, spineIndex: 0);
      final node = _textNodeAt(doc.body!, 0);
      expect(xp.forTextNode(node, 9), '/body/DocFragment[1]/body/p/text().7');
      expect(xp.forTextNode(node, 11), '/body/DocFragment[1]/body/p/text().9');
    });

    test('多文本子节点 → /text()[K].N，K 只数保留节点', () {
      final doc = _parse('<p>\n<em>b</em> c <em>d</em> e</p>');
      final xp = KoreaderXPointer(doc, spineIndex: 0);
      // p 的直接文本子节点：0="\n"(丢), 1=" c ", 2=" e"
      final eNode = _directText(doc.body!.querySelector('p')!, 2);
      expect(
        xp.forTextNode(eNode, 1),
        '/body/DocFragment[1]/body/p/text()[2].1',
      );
      expect(
        xp.forTextNode(eNode, 2),
        '/body/DocFragment[1]/body/p/text()[2].2',
      );
    });

    test('落在被丢弃的块首空白 → 裸元素路径', () {
      final doc = _parse('<p>\n<em>delta</em> epsilon</p>');
      final xp = KoreaderXPointer(doc, spineIndex: 0);
      final blank = _textNodeAt(doc.body!, 0); // "\n"
      expect(xp.forTextNode(blank, 0), '/body/DocFragment[1]/body/p');
    });

    test('pre 保留原始偏移', () {
      final doc = _parse('<pre>ab  cd</pre>');
      final xp = KoreaderXPointer(doc, spineIndex: 0);
      final node = _textNodeAt(doc.body!, 0);
      expect(xp.forTextNode(node, 4), '/body/DocFragment[1]/body/pre/text().4');
    });

    test('spineIndex → DocFragment[N+1]', () {
      final doc = _parse('<p>x</p>');
      final xp = KoreaderXPointer(doc, spineIndex: 10);
      final node = _textNodeAt(doc.body!, 0);
      expect(xp.forTextNode(node, 0), '/body/DocFragment[11]/body/p/text().0');
    });
  });

  group('resolve（解析回落点）', () {
    test('/text().N 折叠偏移 → 原始子串', () {
      final doc = _parse('<p>lambda   mu     nu</p>');
      final xp = KoreaderXPointer(doc, spineIndex: 0);
      expect(
        _resolveSpan(
          xp,
          '/body/DocFragment[1]/body/p/text().7',
          '/body/DocFragment[1]/body/p/text().9',
        ),
        'mu',
      );
    });

    test('/text()[K].N 命中第 K 个保留文本节点', () {
      final doc = _parse('<p>\n<em>b</em> c <em>d</em> e</p>');
      final xp = KoreaderXPointer(doc, spineIndex: 0);
      expect(
        _resolveSpan(
          xp,
          '/body/DocFragment[1]/body/p/text()[1].1',
          '/body/DocFragment[1]/body/p/text()[1].2',
        ),
        'c',
      );
    });

    test('pre 内偏移不折叠', () {
      final doc = _parse('<pre>ab  cd</pre>');
      final xp = KoreaderXPointer(doc, spineIndex: 0);
      expect(
        _resolveSpan(
          xp,
          '/body/DocFragment[1]/body/pre/text().4',
          '/body/DocFragment[1]/body/pre/text().6',
        ),
        'cd',
      );
    });
  });

  group('包裹元素透明化', () {
    test('cfi-skip 包裹被穿透（不占路径层级）', () {
      final doc = _parse('<div><span cfi-skip="1"><p>hi</p></span></div>');
      final xp = KoreaderXPointer(doc, spineIndex: 0);
      final node = _textNodeAt(doc.body!.querySelector('p')!, 0);
      expect(
        xp.forTextNode(node, 0),
        '/body/DocFragment[1]/body/div/p/text().0',
      );
      final point = xp.resolve('/body/DocFragment[1]/body/div/p/text().0')!;
      expect(point.textNode!.data, 'hi');
    });

    test('cfi-inert 元素不参与同级计数', () {
      final doc = _parse('<div><p cfi-inert="1">skip</p><p>keep</p></div>');
      final xp = KoreaderXPointer(doc, spineIndex: 0);
      final keep = doc.body!.querySelectorAll('p')[1];
      final node = _textNodeAt(keep, 0);
      // inert 的第一个 p 被剔除，keep 成为唯一 p → 无 [idx]。
      expect(
        xp.forTextNode(node, 0),
        '/body/DocFragment[1]/body/div/p/text().0',
      );
      final point = xp.resolve('/body/DocFragment[1]/body/div/p/text().0')!;
      expect(point.textNode!.data, 'keep');
    });
  });

  group('round-trip（生成↔解析）', () {
    test('折叠文本往返稳定', () {
      final doc = _parse('<p>lambda   mu     nu</p>');
      final xp = KoreaderXPointer(doc, spineIndex: 3);
      final node = _textNodeAt(doc.body!, 0);
      for (final raw in [0, 9, 11, 16]) {
        final pointer = xp.forTextNode(node, raw);
        final back = xp.resolve(pointer)!;
        // 折叠有损：往返后落到同一折叠格的规范原始偏移。
        final collapsed = KoreaderXPointer.toCollapsedOffset(node.data, raw);
        expect(
          back.rawOffset,
          KoreaderXPointer.toRawOffset(node.data, collapsed),
        );
      }
    });
  });
}
