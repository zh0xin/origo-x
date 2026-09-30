// 文件说明：EPUB 书脊定位器——把「章节归档路径 ↔ crengine DocFragment 序号」对齐，
// 并在同步时按需重解析单章 XHTML，完成「章内拍平偏移 ↔ KOReader XPointer」互转。
// 技术要点：
//   - crengine 的 DocFragment[N] 严格对应 OPF <spine> 里第 N 个 <itemref>（1 基，
//     不区分媒体类型），故 spineIndex = N - 1。这里按**全量 itemref**构建书脊，
//     与 test/koreader_xpointer_oracle_test.dart 验证过的真值编号保持一致。
//   - 归一化规则（百分号解码、相对路径 resolve、去首斜杠）逐字复刻
//     epub_native_parser_io.dart，使 archivePath / href 与原生阅读器章节完全对齐，
//     从而能用章节的 archivePath 反查 spineIndex、用 XPointer 反查章节。
//   - 只在同步（拉取/推送）时对单章重解析，不触碰阅读器热路径。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;

import 'koreader_chapter_map.dart';

/// 解析 XPointer 得到的精确落点：书脊序号 + 章节归档路径 + 章内拍平偏移。
class KoreaderEpubResolvedXPointer {
  const KoreaderEpubResolvedXPointer({
    required this.spineIndex,
    required this.archivePath,
    required this.offsetUtf16,
  });

  final int spineIndex;
  final String archivePath;
  final int offsetUtf16;
}

/// 单本 EPUB 的书脊定位器。用 [open] 构建（读取并解码整包一次）。
class KoreaderEpubLocator {
  KoreaderEpubLocator._(this._files, this._spineArchivePaths);

  /// 解码后的归档条目（键为规范化归档路径）。
  final Map<String, List<int>> _files;

  /// 按 `<spine>` 顺序（全量 itemref）的章节归档路径，下标即 spineIndex。
  final List<String> _spineArchivePaths;

  int get spineLength => _spineArchivePaths.length;

  /// 打开并解析 EPUB。失败时返回 null（同步不可用不应阻断阅读）。
  static KoreaderEpubLocator? open(String epubPath) {
    try {
      final bytes = File(epubPath).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      final files = <String, List<int>>{};
      for (final file in archive.files) {
        if (!file.isFile) continue;
        files[_decodeEpubPath(_normalizeArchivePath(file.name))] =
            file.content as List<int>;
      }
      final spine = _readSpine(files);
      if (spine.isEmpty) return null;
      return KoreaderEpubLocator._(files, spine);
    } catch (_) {
      return null;
    }
  }

  /// 章节归档路径 → 书脊序号（0 基）。找不到返回 null。
  int? spineIndexForArchivePath(String archivePath) {
    final index = _spineArchivePaths.indexOf(archivePath);
    return index < 0 ? null : index;
  }

  /// 书脊序号（0 基）→ 章节归档路径。越界返回 null。
  String? archivePathForSpineIndex(int spineIndex) {
    if (spineIndex < 0 || spineIndex >= _spineArchivePaths.length) return null;
    return _spineArchivePaths[spineIndex];
  }

  /// 章内拍平偏移 → KOReader XPointer。无法定位时返回 null。
  String? buildXPointer({
    required String archivePath,
    required int offsetUtf16,
  }) {
    final spineIndex = spineIndexForArchivePath(archivePath);
    if (spineIndex == null) return null;
    final map = _chapterMap(spineIndex, archivePath);
    if (map == null) return null;
    return map.xpointerForOffset(offsetUtf16);
  }

  /// KOReader XPointer → 精确落点（书脊序号 + 章节 + 章内拍平偏移）。
  KoreaderEpubResolvedXPointer? resolveXPointer(String xpointer) {
    final spineIndex = spineIndexForXPointer(xpointer);
    if (spineIndex == null) return null;
    final archivePath = archivePathForSpineIndex(spineIndex);
    if (archivePath == null) return null;
    final map = _chapterMap(spineIndex, archivePath);
    if (map == null) return null;
    final offset = map.offsetForXPointer(xpointer);
    if (offset == null) return null;
    return KoreaderEpubResolvedXPointer(
      spineIndex: spineIndex,
      archivePath: archivePath,
      offsetUtf16: offset,
    );
  }

  /// 从 `/body/DocFragment[N]/...` 提取书脊序号（0 基）。非该形返回 null。
  static int? spineIndexForXPointer(String xpointer) {
    final match = RegExp(r'/DocFragment\[(\d+)\]').firstMatch(xpointer);
    if (match == null) return null;
    final n = int.tryParse(match.group(1)!);
    if (n == null || n < 1) return null;
    return n - 1;
  }

  /// 判断远端 progress 字符串是否为 crengine 的 EPUB XPointer。
  static bool looksLikeXPointer(String progress) =>
      progress.contains('/DocFragment[');

  KoreaderChapterMap? _chapterMap(int spineIndex, String archivePath) {
    final bytes = _files[archivePath];
    if (bytes == null) return null;
    try {
      final xhtml = utf8.decode(bytes, allowMalformed: true);
      return KoreaderChapterMap.parse(xhtml, spineIndex: spineIndex);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ OPF 解析

  static List<String> _readSpine(Map<String, List<int>> files) {
    final containerBytes = files[_containerKey];
    if (containerBytes == null) return const [];
    final container = html_parser.parse(
      utf8.decode(containerBytes, allowMalformed: true),
    );
    final packagePath = container
        .querySelector('rootfile')
        ?.attributes['full-path'];
    if (packagePath == null || packagePath.trim().isEmpty) return const [];
    final normalizedPackagePath = _normalizeArchivePath(packagePath);
    final packageBytes = files[normalizedPackagePath];
    if (packageBytes == null) return const [];
    final package = html_parser.parse(
      utf8.decode(packageBytes, allowMalformed: true),
    );

    final archivePathById = <String, String>{};
    for (final item in package.querySelectorAll('manifest item')) {
      final id = item.attributes['id'];
      final href = item.attributes['href'];
      if (id == null || href == null) continue;
      archivePathById[id] = _resolveArchivePath(normalizedPackagePath, href);
    }

    final spine = <String>[];
    for (final itemRef
        in package.querySelector('spine')?.querySelectorAll('itemref') ??
            const []) {
      final idRef = itemRef.attributes['idref'];
      final archivePath = idRef == null ? null : archivePathById[idRef];
      if (archivePath == null) continue;
      spine.add(archivePath);
    }
    return spine;
  }

  static const String _containerKey = 'META-INF/container.xml';

  // ---------------------------------------------- 路径归一化（复刻自原生解析器）

  static String _normalizeArchivePath(String value) {
    final normalized = p.posix.normalize(
      _decodeEpubPath(
        value.split('#').first.split('?').first,
      ).replaceAll('\\', '/'),
    );
    return normalized.startsWith('/') ? normalized.substring(1) : normalized;
  }

  static String _resolveArchivePath(String ownerPath, String reference) {
    final uriPath = reference.split('#').first.split('?').first;
    return _normalizeArchivePath(
      p.posix.join(p.posix.dirname(ownerPath), _decodeEpubPath(uriPath)),
    );
  }

  static String _decodeEpubPath(String value) {
    final output = StringBuffer();
    var index = 0;
    while (index < value.length) {
      if (!_hasPercentByteAt(value, index)) {
        output.write(value[index]);
        index++;
        continue;
      }
      final start = index;
      final bytes = <int>[];
      while (_hasPercentByteAt(value, index)) {
        bytes.add(int.parse(value.substring(index + 1, index + 3), radix: 16));
        index += 3;
      }
      try {
        output.write(utf8.decode(bytes, allowMalformed: false));
      } on FormatException {
        output.write(value.substring(start, index));
      }
    }
    return output.toString();
  }

  static bool _hasPercentByteAt(String value, int index) =>
      index + 2 < value.length &&
      value.codeUnitAt(index) == 0x25 &&
      _isHexDigit(value.codeUnitAt(index + 1)) &&
      _isHexDigit(value.codeUnitAt(index + 2));

  static bool _isHexDigit(int codeUnit) =>
      (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x46) ||
      (codeUnit >= 0x61 && codeUnit <= 0x66);
}
