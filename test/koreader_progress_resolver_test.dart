import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/koreader/koreader_progress_resolver.dart';

void main() {
  group('resolveKoreaderProgression', () {
    test('百分比 0 落在第一章开头', () {
      final resolved = resolveKoreaderProgression(0, [1000, 1000, 1000]);
      expect(resolved.chapterIndex, 0);
      expect(resolved.offsetInChapter, 0);
    });

    test('百分比 1 落在最后一章末尾（不越界）', () {
      final resolved = resolveKoreaderProgression(1, [1000, 1000, 1000]);
      expect(resolved.chapterIndex, 2);
      expect(resolved.offsetInChapter, 999);
    });

    test('章节边界处的百分比落在下一章开头', () {
      final resolved = resolveKoreaderProgression(1 / 3, [1000, 1000, 1000]);
      expect(resolved.chapterIndex, 1);
      expect(resolved.offsetInChapter, 0);
    });

    test('章内中段按章长比例换算偏移', () {
      // 0.5 * 3 = 1.5 → 第 2 章（下标 1），章内 50%
      final resolved = resolveKoreaderProgression(0.5, [1000, 2000, 1000]);
      expect(resolved.chapterIndex, 1);
      expect(resolved.offsetInChapter, 1000);
    });

    test('章节长度不均时按各章实际长度换算', () {
      // 0.25 * 3 = 0.75 → 第 1 章（下标 0），章内 75%
      final resolved = resolveKoreaderProgression(0.25, [4000, 100, 100]);
      expect(resolved.chapterIndex, 0);
      expect(resolved.offsetInChapter, 3000);
    });

    test('超出范围的百分比被夹紧', () {
      expect(
        resolveKoreaderProgression(-0.5, [1000, 1000]),
        const KoreaderResolvedPosition(chapterIndex: 0, offsetInChapter: 0),
      );
      expect(
        resolveKoreaderProgression(1.5, [1000, 1000]),
        const KoreaderResolvedPosition(chapterIndex: 1, offsetInChapter: 999),
      );
    });

    test('空章节列表退化为 (0, 0) 而不抛异常', () {
      expect(
        resolveKoreaderProgression(0.5, const []),
        const KoreaderResolvedPosition(chapterIndex: 0, offsetInChapter: 0),
      );
    });

    test('零长度章节不产生越界偏移', () {
      final resolved = resolveKoreaderProgression(0, [0, 1000]);
      expect(resolved.chapterIndex, 0);
      expect(resolved.offsetInChapter, 0);
    });

    test('单章节书籍的比例换算', () {
      expect(
        resolveKoreaderProgression(0.5, [1000]),
        const KoreaderResolvedPosition(chapterIndex: 0, offsetInChapter: 500),
      );
    });

    test('结果满足 offset 始终小于所属章节长度', () {
      final lengths = [10, 5000, 3, 7777, 42];
      for (var step = 0; step <= 100; step++) {
        final resolved = resolveKoreaderProgression(step / 100, lengths);
        expect(resolved.chapterIndex, inInclusiveRange(0, lengths.length - 1));
        expect(resolved.offsetInChapter, greaterThanOrEqualTo(0));
        expect(
          resolved.offsetInChapter,
          lessThan(lengths[resolved.chapterIndex]),
        );
      }
    });
  });

  group('KoreaderResolvedPosition', () {
    test('值相等语义', () {
      expect(
        const KoreaderResolvedPosition(chapterIndex: 1, offsetInChapter: 2),
        const KoreaderResolvedPosition(chapterIndex: 1, offsetInChapter: 2),
      );
      expect(
        const KoreaderResolvedPosition(chapterIndex: 1, offsetInChapter: 2),
        isNot(
          const KoreaderResolvedPosition(chapterIndex: 1, offsetInChapter: 3),
        ),
      );
    });
  });
}
