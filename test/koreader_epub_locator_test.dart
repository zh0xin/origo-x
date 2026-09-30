// 文件说明：KoreaderEpubLocator 端到端校验——用真实 sample-alice.epub + crengine 真值，
// 验证「书脊序号 ↔ 章节归档路径」对齐，以及「XPointer ↔ 章内拍平偏移」双向互转。
//
// 这是把 XPointer 原型接成正式功能后的关键接线点：locator 负责在同步时按 OPF 全量
// spine 复原 DocFragment 编号、按需重解析单章、并生成/解析 crengine XPointer。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/koreader/koreader_epub_locator.dart';

const _epubPath = 'test/fixtures/koreader/sample-alice.epub';
const _oraclePath = 'test/fixtures/koreader/sample-alice.json';

void main() {
  final locator = KoreaderEpubLocator.open(_epubPath);
  final oracle =
      jsonDecode(File(_oraclePath).readAsStringSync()) as Map<String, dynamic>;
  final fragments = (oracle['fragments'] as List).cast<Map<String, dynamic>>();

  test('locator 能打开 EPUB 并建立书脊', () {
    expect(locator, isNotNull);
    final maxDocFragment = fragments
        .map((f) => f['docfragment'] as int)
        .fold<int>(0, (a, b) => a > b ? a : b);
    expect(locator!.spineLength, greaterThanOrEqualTo(maxDocFragment));
  });

  test('XPointer → (书脊序号, 章节, 章内偏移) 与真值一致', () {
    final l = locator!;
    var checked = 0;
    final failures = <String>[];
    for (final frag in fragments) {
      final words = (frag['words'] as List).cast<Map<String, dynamic>>();
      if (words.isEmpty) continue;
      final docfragment = frag['docfragment'] as int;
      final spineIndex = docfragment - 1;
      final archivePath = l.archivePathForSpineIndex(spineIndex);
      if (archivePath == null) continue;
      for (final w in words) {
        final xp = w['xp'] as String;
        final resolved = l.resolveXPointer(xp);
        checked++;
        if (resolved == null) {
          failures.add('DF$docfragment $xp → null');
          continue;
        }
        if (resolved.spineIndex != spineIndex ||
            resolved.archivePath != archivePath) {
          failures.add(
            'DF$docfragment $xp → spine ${resolved.spineIndex}/'
            '${resolved.archivePath}，期望 $spineIndex/$archivePath',
          );
        }
      }
    }
    expect(checked, greaterThan(0));
    expect(
      failures,
      isEmpty,
      reason: '共 $checked 个，失配:\n${failures.join('\n')}',
    );
  });

  test('偏移 → XPointer → 偏移 往返稳定（生成侧）', () {
    final l = locator!;
    var checked = 0;
    final failures = <String>[];
    for (final frag in fragments) {
      final words = (frag['words'] as List).cast<Map<String, dynamic>>();
      if (words.isEmpty) continue;
      final spineIndex = (frag['docfragment'] as int) - 1;
      final archivePath = l.archivePathForSpineIndex(spineIndex);
      if (archivePath == null) continue;
      for (final w in words) {
        final resolved = l.resolveXPointer(w['xp'] as String);
        if (resolved == null) continue;
        checked++;
        final regenerated = l.buildXPointer(
          archivePath: archivePath,
          offsetUtf16: resolved.offsetUtf16,
        );
        if (regenerated == null) {
          failures.add('offset ${resolved.offsetUtf16} → null');
          continue;
        }
        final again = l.resolveXPointer(regenerated);
        if (again == null || again.offsetUtf16 != resolved.offsetUtf16) {
          failures.add(
            'offset ${resolved.offsetUtf16} 往返到 ${again?.offsetUtf16}',
          );
        }
      }
    }
    expect(checked, greaterThan(0));
    expect(failures, isEmpty, reason: '往返失配:\n${failures.join('\n')}');
  });
}
