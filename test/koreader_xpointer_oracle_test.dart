// 文件说明：用真实 EPUB（sample-alice）+ crengine 真值，端到端校验 KOReader
// XPointer 的解析与「拍平偏移 ↔ XPointer」关联层。
//
// 真值来自 readest 的 fixtures/crengine/sample-alice.json：每个 word 的 xp/xp_end
// 是 KOReader（crengine）在同一本书上产出的真实 XPointer，text 是该区间应命中的词。
// 如果本项目的 Dart 实现能在同一份 spine XHTML 上把 xp..xp_end 解析成同一个词，
// 就证明「能读懂 KOReader 写的落点」；再经关联层映射回拍平偏移仍取到同一个词，
// 就证明「能接回本项目阅读器的定位坐标」。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'package:xxread/services/sync/koreader/koreader_chapter_map.dart';
import 'package:xxread/services/sync/koreader/koreader_xpointer.dart';
import 'package:html/parser.dart' as html_parser;

const _epubPath = 'test/fixtures/koreader/sample-alice.epub';
const _oraclePath = 'test/fixtures/koreader/sample-alice.json';

/// 归一化 zip 路径（去掉 ./、解析 ..、去首斜杠）。
String _normalizeZip(String path) {
  final parts = <String>[];
  for (final seg in path.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

String _dirOf(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? '' : path.substring(0, i);
}

class _Epub {
  _Epub(this.files);
  final Map<String, ArchiveFile> files;

  String readText(String zipPath) {
    final f = files[_normalizeZip(zipPath)];
    if (f == null) throw StateError('missing zip entry: $zipPath');
    return utf8.decode(f.content as List<int>, allowMalformed: true);
  }

  /// 按 <spine> 顺序返回各 itemref 的 zip 路径（= crengine DocFragment 顺序）。
  List<String> spineHrefs() {
    final container = XmlDocument.parse(readText('META-INF/container.xml'));
    final opfPath = container
        .findAllElements('rootfile')
        .first
        .getAttribute('full-path')!;
    final opfDir = _dirOf(_normalizeZip(opfPath));
    final opf = XmlDocument.parse(readText(opfPath));

    final hrefById = <String, String>{};
    for (final item in opf.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        hrefById[id] = _normalizeZip(opfDir.isEmpty ? href : '$opfDir/$href');
      }
    }
    final result = <String>[];
    for (final itemref in opf.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref');
      final href = idref == null ? null : hrefById[idref];
      if (href != null) result.add(href);
    }
    return result;
  }
}

_Epub _loadEpub() {
  final bytes = File(_epubPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  final files = <String, ArchiveFile>{};
  for (final f in archive.files) {
    if (f.isFile) files[_normalizeZip(f.name)] = f;
  }
  return _Epub(files);
}

/// 解析 xp/xp_end（同一文本节点内）取原始子串。
String? _resolveWord(KoreaderXPointer xp, String start, String end) {
  final a = xp.resolve(start);
  final b = xp.resolve(end);
  if (a?.textNode == null || b?.textNode == null) return null;
  if (!identical(a!.textNode, b!.textNode)) return null;
  final data = a.textNode!.data;
  final lo = a.rawOffset!.clamp(0, data.length);
  final hi = b.rawOffset!.clamp(0, data.length);
  if (hi < lo) return null;
  return data.substring(lo, hi);
}

void main() {
  final epub = _loadEpub();
  final spine = epub.spineHrefs();
  final oracle =
      jsonDecode(File(_oraclePath).readAsStringSync()) as Map<String, dynamic>;
  final fragments = (oracle['fragments'] as List).cast<Map<String, dynamic>>();

  test('spine 顺序与 crengine DocFragment 数量一致', () {
    final maxDocFragment = fragments
        .map((f) => f['docfragment'] as int)
        .fold<int>(0, (a, b) => a > b ? a : b);
    expect(
      spine.length,
      greaterThanOrEqualTo(maxDocFragment),
      reason: 'spine 项数应 >= 最大 DocFragment 号',
    );
  });

  test('crengine XPointer 解析命中同一个词（XPointer 编解码 vs 真值）', () {
    final failures = <String>[];
    var checked = 0;
    for (final frag in fragments) {
      final words = (frag['words'] as List).cast<Map<String, dynamic>>();
      if (words.isEmpty) continue;
      final docfragment = frag['docfragment'] as int;
      final spineIndex = docfragment - 1;
      if (spineIndex < 0 || spineIndex >= spine.length) continue;
      final doc = html_parser.parse(epub.readText(spine[spineIndex]));
      final xp = KoreaderXPointer(doc, spineIndex: spineIndex);
      for (final w in words) {
        final expected = w['text'] as String;
        final got = _resolveWord(xp, w['xp'] as String, w['xp_end'] as String);
        checked++;
        if (got != expected) {
          failures.add('DF$docfragment ${w['xp']}\n  期望「$expected」得到「$got」');
        }
      }
    }
    expect(checked, greaterThan(0));
    expect(
      failures,
      isEmpty,
      reason: '共 $checked 个词，失配:\n${failures.join('\n')}',
    );
  });

  test('关联层：XPointer → 拍平偏移仍取到同一个词（bridge）', () {
    final failures = <String>[];
    var checked = 0;
    for (final frag in fragments) {
      final words = (frag['words'] as List).cast<Map<String, dynamic>>();
      if (words.isEmpty) continue;
      final docfragment = frag['docfragment'] as int;
      final spineIndex = docfragment - 1;
      if (spineIndex < 0 || spineIndex >= spine.length) continue;
      final map = KoreaderChapterMap.parse(
        epub.readText(spine[spineIndex]),
        spineIndex: spineIndex,
      );
      for (final w in words) {
        final expected = w['text'] as String;
        final off = map.offsetForXPointer(w['xp'] as String);
        checked++;
        if (off == null) {
          failures.add('DF$docfragment ${w['xp']} → 偏移 null');
          continue;
        }
        final end = (off + expected.length).clamp(0, map.plainText.length);
        final got = map.plainText.substring(
          off.clamp(0, map.plainText.length),
          end,
        );
        if (got != expected) {
          failures.add(
            'DF$docfragment ${w['xp']}\n  期望「$expected」得到「$got」@$off',
          );
        }
      }
    }
    expect(checked, greaterThan(0));
    expect(
      failures,
      isEmpty,
      reason: '共 $checked 个词，失配:\n${failures.join('\n')}',
    );
  });

  test('关联层：拍平偏移 → XPointer 往返回到同一文本节点', () {
    for (final frag in fragments) {
      final words = (frag['words'] as List).cast<Map<String, dynamic>>();
      if (words.isEmpty) continue;
      final spineIndex = (frag['docfragment'] as int) - 1;
      if (spineIndex < 0 || spineIndex >= spine.length) continue;
      final map = KoreaderChapterMap.parse(
        epub.readText(spine[spineIndex]),
        spineIndex: spineIndex,
      );
      for (final w in words) {
        final off = map.offsetForXPointer(w['xp'] as String);
        if (off == null) continue;
        final roundTrip = map.xpointerForOffset(off);
        expect(roundTrip, isNotNull);
        // 往返后应能再次解析且落回同一文本节点。
        final again = map.offsetForXPointer(roundTrip!);
        expect(again, isNotNull);
      }
    }
  });
}
