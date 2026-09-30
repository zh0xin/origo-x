// 文件说明：KOReader 文档标识（document id）计算——partial MD5 抽样算法与文件名 MD5。
// 技术要点：严格复刻 KOReader frontend/util.lua 的 util.partialMD5 抽样偏移，
// 偏移或抽样规则一旦有偏差，与 KOReader 之间的书籍匹配就会完全失效。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'koreader_models.dart';

/// 每次抽样的字节数。KOReader 的 `util.partialMD5` 中 `size = 1024`。
const int koreaderPartialMd5SampleSize = 1024;

/// KOReader `util.partialMD5` 的抽样偏移（字节），共 12 个采样点。
///
/// KOReader 原实现为：
///
/// ```lua
/// local step, size = 1024, 1024
/// for i = -1, 10 do
///     file:seek("set", lshift(step, 2*i))
///     local sample = file:read(size)
///     if sample then update(sample) else break end
/// end
/// ```
///
/// 其中 `lshift` 是 LuaJIT 的 `bit.lshift`，**移位量会被掩码到 5 位**。
/// `i = -1` 时移位量为 -2，掩码后为 30，`1024 << 30` 在 32 位下溢出为 0，
/// 因此第一个采样点是文件头（偏移 0），而不是某些二手文档所写的 512。
/// 展开 `i = 0..10` 得到 1024、4096、16384…… 与 `util.lua` 上方注释列出的
/// 偏移清单一致（该注释未列出偏移 0 的头块）。
///
/// 注意：网上流传的一份「非官方 kosync 规范」把偏移写成
/// `512, 2048, 8192, 32768...`，其参考实现也无法运行，是错的。以本清单为准。
const List<int> koreaderPartialMd5Offsets = <int>[
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
];

/// 计算书籍在 kosync 服务器上的 document id。
///
/// - [KoreaderChecksumMethod.partialMd5]：内容抽样 MD5，与 KOReader 默认行为一致，
///   文件改名或移动不影响结果。
/// - [KoreaderChecksumMethod.filename]：文件名（含扩展名）的 MD5。KOReader 的
///   `getFileName()` 用 `util.splitFilePathName` 拆出的是 basename，故此处取 basename。
Future<String> koreaderDocumentId({
  required String filePath,
  required KoreaderChecksumMethod method,
}) async {
  switch (method) {
    case KoreaderChecksumMethod.filename:
      return md5.convert(utf8.encode(p.basename(filePath))).toString();
    case KoreaderChecksumMethod.partialMd5:
      return koreaderPartialMd5(filePath);
  }
}

/// 按 KOReader 的抽样规则计算文件的 partial MD5，返回小写十六进制。
///
/// 与 KOReader 一致的两处细节：
/// - 偏移超出文件末尾时读取为空，循环**中断**，后续采样点不再参与；
/// - 文件末尾最后一个采样点即使不足 [koreaderPartialMd5SampleSize] 字节，
///   只要读到了内容就仍要参与哈希。
///
/// 最多读取 12 KiB，开销与文件大小无关，无需放入 isolate。
Future<String> koreaderPartialMd5(String filePath) async {
  final file = File(filePath);
  final handle = await file.open();
  try {
    final buffer = BytesBuilder(copy: false);
    for (final offset in koreaderPartialMd5Offsets) {
      await handle.setPosition(offset);
      final chunk = await handle.read(koreaderPartialMd5SampleSize);
      if (chunk.isEmpty) break;
      buffer.add(chunk);
    }
    return md5.convert(buffer.takeBytes()).toString();
  } finally {
    await handle.close();
  }
}

/// 该书籍文件是否可用于计算内容型 document id。
///
/// 在线书源书籍没有落盘文件，无法参与内容抽样，只能跳过同步。
Future<bool> koreaderDocumentIdAvailable(String? filePath) async {
  if (filePath == null || filePath.isEmpty) return false;
  if (filePath.startsWith('web-book://')) return false;
  return File(filePath).exists();
}
