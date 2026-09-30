// 文件说明：把 kosync 的全局百分比换算回「章节下标 + 章内偏移」。
// 技术要点：纯函数，无副作用，便于单元测试。

/// 换算结果。
///
/// [offsetInChapter] 为章内的 UTF-16 偏移，可直接交给原生阅读器的
/// 锚点恢复管线（`_anchorOffset`）使用。
class KoreaderResolvedPosition {
  const KoreaderResolvedPosition({
    required this.chapterIndex,
    required this.offsetInChapter,
  });

  final int chapterIndex;
  final int offsetInChapter;

  @override
  bool operator ==(Object other) =>
      other is KoreaderResolvedPosition &&
      other.chapterIndex == chapterIndex &&
      other.offsetInChapter == offsetInChapter;

  @override
  int get hashCode => Object.hash(chapterIndex, offsetInChapter);

  @override
  String toString() =>
      'KoreaderResolvedPosition(chapter: $chapterIndex, offset: $offsetInChapter)';
}

/// 将全局阅读百分比换算为章节下标与章内偏移。
///
/// 这是本应用进度公式 `(chapterIndex + chapterProgress) / chapterCount`
/// （见 `native_reader_page.dart` 的 `_saveCanonicalProgress`）的逆运算。
///
/// ⚠️ 该公式按**章节数均分**，而 KOReader 的 `percentage` 基于它自己的
/// 虚拟分页，两者并非同一度量。因此换算结果是近似位置，不是精确复原。
///
/// [chapterLengths] 为各章正文字符数（UTF-16 长度）。
/// 章节列表为空时返回 (0, 0)。
KoreaderResolvedPosition resolveKoreaderProgression(
  double progression,
  List<int> chapterLengths,
) {
  final count = chapterLengths.length;
  if (count == 0) {
    return const KoreaderResolvedPosition(chapterIndex: 0, offsetInChapter: 0);
  }
  final clamped = progression.clamp(0.0, 1.0);
  final raw = clamped * count;
  var index = raw.floor();
  if (index >= count) index = count - 1;
  if (index < 0) index = 0;
  final fraction = raw - index;
  final length = chapterLengths[index];
  if (length <= 0) {
    return KoreaderResolvedPosition(chapterIndex: index, offsetInChapter: 0);
  }
  var offset = (fraction * length).round();
  if (offset >= length) offset = length - 1;
  if (offset < 0) offset = 0;
  return KoreaderResolvedPosition(chapterIndex: index, offsetInChapter: offset);
}
