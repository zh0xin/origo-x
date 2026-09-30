import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/koreader/koreader_models.dart';
import 'package:xxread/services/sync/koreader/koreader_partial_md5.dart';

/// 独立的参考实现：按 KOReader `util.partialMD5` 的抽样规则拼接采样字节。
///
/// 刻意不复用被测代码的循环与文件读取方式，以便真正起到交叉校验作用。
String referencePartialMd5(List<int> bytes) {
  final sample = <int>[];
  for (var i = -1; i <= 10; i++) {
    // 复刻 LuaJIT bit.lshift：移位量掩码到 5 位，结果截断为 32 位。
    final offset = (1024 << ((2 * i) & 31)) & 0xFFFFFFFF;
    if (offset >= bytes.length) break;
    final end = offset + 1024;
    sample.addAll(
      bytes.sublist(offset, end > bytes.length ? bytes.length : end),
    );
  }
  return md5.convert(sample).toString();
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('koreader_md5_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<File> writeFile(String name, List<int> bytes) async {
    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  group('抽样偏移', () {
    test('与 KOReader util.partialMD5 展开结果一致', () {
      // LuaJIT 的 bit.lshift 会把移位量掩码到 5 位：
      // i = -1 时移位量为 -2 → 30，1024 << 30 在 32 位下溢出为 0。
      // 这正是第一个采样点是文件头而非偏移 512 的原因。
      expect(koreaderPartialMd5Offsets, const <int>[
        0,
        1024,
        4096,
        16384,
        65536,
        262144,
        1048576,
        4194304,
        16777216,
        67108864,
        268435456,
        1073741824,
      ]);
    });

    test('偏移严格递增且首项为 0', () {
      expect(koreaderPartialMd5Offsets.first, 0);
      for (var i = 1; i < koreaderPartialMd5Offsets.length; i++) {
        expect(
          koreaderPartialMd5Offsets[i],
          greaterThan(koreaderPartialMd5Offsets[i - 1]),
        );
      }
    });

    test('首个偏移不是流传文档所写的 512', () {
      expect(koreaderPartialMd5Offsets.first, isNot(512));
      expect(koreaderPartialMd5Offsets.contains(512), isFalse);
      expect(koreaderPartialMd5Offsets.contains(2048), isFalse);
      expect(koreaderPartialMd5Offsets[1], 1024);
    });
  });

  group('koreaderPartialMd5', () {
    test('与参考实现一致（小文件：仅头块参与）', () async {
      final bytes = List<int>.generate(3000, (i) => i % 256);
      final file = await writeFile('small.bin', bytes);

      expect(await koreaderPartialMd5(file.path), referencePartialMd5(bytes));
    });

    test('与参考实现一致（多采样点）', () async {
      // 1 MiB + 少量，恰好覆盖到 1048576 这个采样点。
      final bytes = List<int>.generate(1100000, (i) => (i * 7) % 256);
      final file = await writeFile('medium.bin', bytes);

      expect(await koreaderPartialMd5(file.path), referencePartialMd5(bytes));
    });

    test('不足 1024 字节的文件仍产生头块的 MD5', () async {
      final bytes = List<int>.generate(258, (i) => i % 256);
      final file = await writeFile('tiny.bin', bytes);

      expect(
        await koreaderPartialMd5(file.path),
        md5.convert(bytes).toString(),
      );
      expect(await koreaderPartialMd5(file.path), referencePartialMd5(bytes));
    });

    test('文件尾部的部分采样块仍参与哈希', () async {
      // 文件长度略大于第二个采样点 1024，使偏移 4096 越界中断，
      // 而偏移 1024 处只有部分内容可读。
      final bytes = List<int>.generate(1500, (i) => (i * 3) % 256);
      final file = await writeFile('partial.bin', bytes);

      final expected = referencePartialMd5(bytes);
      expect(await koreaderPartialMd5(file.path), expected);

      // 若错误地要求整块或跳过不完整块，结果会不同。
      final onlyFirstBlock = md5.convert(bytes.sublist(0, 1024)).toString();
      expect(expected, isNot(onlyFirstBlock));
    });

    test('前 12 KiB 相同但尾部不同的文件得到相同摘要', () async {
      // KOReader 只在尾部（PDF 高亮）追加数据时也会依赖这一特性。
      final head = List<int>.generate(12288, (i) => i % 256);
      final a = await writeFile('a.bin', [...head, 1, 2, 3]);
      final b = await writeFile('b.bin', [...head, 9, 9, 9, 9, 9]);

      expect(
        await koreaderPartialMd5(a.path),
        await koreaderPartialMd5(b.path),
      );
    });

    test('内容不同的文件得到不同摘要', () async {
      final a = await writeFile(
        'c.bin',
        List<int>.generate(5000, (i) => i % 256),
      );
      final b = await writeFile(
        'd.bin',
        List<int>.generate(5000, (i) => (i + 1) % 256),
      );

      expect(
        await koreaderPartialMd5(a.path),
        isNot(await koreaderPartialMd5(b.path)),
      );
    });
  });

  group('koreaderDocumentId', () {
    test('filename 模式为 basename（含扩展名）的 MD5', () async {
      final file = await writeFile('My Book.epub', const [1, 2, 3]);

      expect(
        await koreaderDocumentId(
          filePath: file.path,
          method: KoreaderChecksumMethod.filename,
        ),
        md5.convert(utf8.encode('My Book.epub')).toString(),
      );
    });

    test('filename 模式不受目录影响，仅取决文件名', () async {
      final nested = Directory('${tempDir.path}${Platform.pathSeparator}sub');
      await nested.create();
      final nestedFile = File(
        '${nested.path}${Platform.pathSeparator}My Book.epub',
      );
      await nestedFile.writeAsBytes(const [9, 9, 9]);

      expect(
        await koreaderDocumentId(
          filePath: nestedFile.path,
          method: KoreaderChecksumMethod.filename,
        ),
        md5.convert(utf8.encode('My Book.epub')).toString(),
      );
    });

    test('partialMd5 模式忽略文件名变化', () async {
      final bytes = List<int>.generate(4000, (i) => i % 256);
      final a = await writeFile('first.epub', bytes);
      final b = await writeFile('renamed.epub', bytes);

      expect(
        await koreaderDocumentId(
          filePath: a.path,
          method: KoreaderChecksumMethod.partialMd5,
        ),
        await koreaderDocumentId(
          filePath: b.path,
          method: KoreaderChecksumMethod.partialMd5,
        ),
      );
    });
  });

  group('koreaderDocumentIdAvailable', () {
    test('存在的文件返回 true', () async {
      final file = await writeFile('exists.bin', const [1]);
      expect(await koreaderDocumentIdAvailable(file.path), isTrue);
    });

    test('空路径与不存在的文件返回 false', () async {
      expect(await koreaderDocumentIdAvailable(null), isFalse);
      expect(await koreaderDocumentIdAvailable(''), isFalse);
      expect(
        await koreaderDocumentIdAvailable('${tempDir.path}/missing.epub'),
        isFalse,
      );
    });

    test('Web 端虚拟路径返回 false（在线书籍无落盘文件）', () async {
      expect(await koreaderDocumentIdAvailable('web-book://abc123'), isFalse);
    });
  });
}
