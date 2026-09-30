import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/opds/models/opds_feed.dart';
import 'package:xxread/opds/services/opds_parser.dart';

Uint8List _xml(String body) => Uint8List.fromList(utf8.encode(body));

const String _base = 'https://catalog.example.org/opds';
final Uri _exampleUri = Uri.parse('https://example.org/a.jpg');

/// 拼接期望的绝对地址，避免在断言里重复写字面量。
String _abs(String path) => '$_base$path';

void main() {
  group('导航型 feed', () {
    test('解析条目、分类链接与分页关系', () {
      final feed = OpdsParser.parse(
        _xml('''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>My Catalog</title>
  <id>urn:root</id>
  <link rel="self" href="/opds" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
  <link rel="start" href="/opds" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
  <link rel="next" href="/opds?page=2"/>
  <entry>
    <title>Fiction</title>
    <id>urn:fiction</id>
    <link rel="subsection" href="/opds/fiction" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
  </entry>
  <entry>
    <title>Poetry</title>
    <id>urn:poetry</id>
    <link rel="subsection" href="/opds/poetry"/>
  </entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.title, 'My Catalog');
      expect(feed.kind, OpdsFeedKind.navigation);
      expect(feed.entries, hasLength(2));
      expect(feed.entries.first.title, 'Fiction');
      expect(feed.entries.first.isNavigation, isTrue);
      expect(feed.startUrl.toString(), '$_base');
      expect(feed.nextUrl.toString(), _abs('?page=2'));
      expect(feed.hasNextPage, isTrue);
      expect(feed.hasPreviousPage, isFalse);
    });

    test('self 链接缺失时回退到请求地址', () {
      final feed = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Bare</title>
  <entry><title>A</title><id>1</id></entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.selfUrl.toString(), _base);
    });

    test('prev 关系被识别为上一页', () {
      final feed = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Paged</title>
  <link rel="prev" href="/opds?page=1"/>
  <link rel="next" href="/opds?page=3"/>
  <entry><title>A</title><id>1</id><link rel="subsection" href="/opds/a"/></entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.hasPreviousPage, isTrue);
      expect(feed.hasNextPage, isTrue);
      expect(feed.previousUrl.toString(), _abs('?page=1'));
    });
  });

  group('获取型 feed', () {
    const acquisitionFeed = '''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:dc="http://purl.org/dc/elements/1.1/">
  <title>Recent</title>
  <id>urn:recent</id>
  <link rel="self" href="/opds/recent" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
  <entry>
    <title>The Silent Book</title>
    <id>urn:book:1</id>
    <dc:creator>Ada Lovelace</dc:creator>
    <summary>A short description.</summary>
    <updated>2026-01-02T03:04:05Z</updated>
    <link rel="http://opds-spec.org/image" href="/covers/1.jpg" type="image/jpeg"/>
    <link rel="http://opds-spec.org/image/thumbnail" href="/covers/1-thumb.jpg" type="image/jpeg"/>
    <link rel="http://opds-spec.org/acquisition" href="/files/1.epub" type="application/epub+zip"/>
    <link rel="http://opds-spec.org/acquisition/open-access" href="/files/1.pdf" type="application/pdf"/>
  </entry>
</feed>
''';

    test('解析作者、摘要、封面与获取链接', () {
      final feed = OpdsParser.parse(
        _xml(acquisitionFeed),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.kind, OpdsFeedKind.acquisition);
      final entry = feed.entries.single;
      expect(entry.title, 'The Silent Book');
      expect(entry.author, 'Ada Lovelace');
      expect(entry.summary, 'A short description.');
      expect(entry.updated, isNotNull);
      expect(
        entry.thumbnailUrl.toString(),
        'https://catalog.example.org/covers/1-thumb.jpg',
      );
      expect(
        entry.coverUrl.toString(),
        'https://catalog.example.org/covers/1.jpg',
      );
      expect(entry.acquisitions, hasLength(2));
      expect(entry.acquisitions.first.href.path, '/files/1.epub');
      expect(entry.acquisitions.last.type, 'application/pdf');
      expect(entry.isNavigation, isFalse);
    });

    test('按内容推断 feed 类型（无 kind 声明时）', () {
      final feed = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Undeclared</title>
  <entry>
    <title>Book</title>
    <id>1</id>
    <link rel="http://opds-spec.org/acquisition" href="/b.epub" type="application/epub+zip"/>
  </entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.kind, OpdsFeedKind.acquisition);
    });

    test('open-access 链接也视为获取链接', () {
      final entry = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>T</title>
  <entry>
    <title>B</title>
    <id>1</id>
    <link rel="http://opds-spec.org/acquisition/open-access" href="/b.pdf" type="application/pdf"/>
  </entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      ).entries.single;

      expect(entry.acquisitions, hasLength(1));
    });

    test('atom:author 优先于 dc:creator', () {
      final entry = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <title>T</title>
  <entry>
    <title>B</title>
    <id>1</id>
    <author><name>Atom Author</name></author>
    <dc:creator>DC Author</dc:creator>
    <link rel="http://opds-spec.org/acquisition" href="/b.epub"/>
  </entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      ).entries.single;

      expect(entry.author, 'Atom Author');
    });

    test('content 可作为摘要回退', () {
      final entry = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>T</title>
  <entry>
    <title>B</title>
    <id>1</id>
    <content>Body text</content>
    <link rel="http://opds-spec.org/acquisition" href="/b.epub"/>
  </entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      ).entries.single;

      expect(entry.summary, 'Body text');
    });
  });

  group('链接解析', () {
    test('相对路径按 feed 地址解析', () {
      final feed = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>T</title>
  <entry><title>A</title><id>1</id><link rel="subsection" href="child"/></entry>
</feed>
'''),
        baseUrl: Uri.parse('$_base/catalog'),
      );

      expect(feed.entries.single.links.single.href.toString(), '$_base/child');
    });

    test('绝对地址原样保留', () {
      final feed = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>T</title>
  <entry>
    <title>A</title>
    <id>1</id>
    <link rel="http://opds-spec.org/acquisition" href="https://cdn.example.net/a.epub"/>
  </entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      );

      expect(
        feed.entries.single.acquisitions.single.href.toString(),
        'https://cdn.example.net/a.epub',
      );
    });

    test('非 http(s) 链接被丢弃', () {
      final feed = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>T</title>
  <entry>
    <title>A</title>
    <id>1</id>
    <link rel="http://opds-spec.org/acquisition" href="file:///etc/passwd"/>
    <link rel="http://opds-spec.org/acquisition" href="javascript:alert(1)"/>
  </entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.entries.single.acquisitions, isEmpty);
    });

    test('缺少 href 的链接被忽略', () {
      final feed = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>T</title>
  <entry><title>A</title><id>1</id><link rel="subsection" type="application/atom+xml"/></entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.entries.single.links, isEmpty);
    });
  });

  group('异常与边界', () {
    test('非 XML 内容被拒绝', () {
      expect(
        () => OpdsParser.parse(
          _xml('not xml at all <<<'),
          baseUrl: Uri.parse(_base),
        ),
        throwsA(isA<OpdsParseException>()),
      );
    });

    test('非 feed 根元素被拒绝', () {
      expect(
        () => OpdsParser.parse(
          _xml('<?xml version="1.0"?><html><body/></html>'),
          baseUrl: Uri.parse(_base),
        ),
        throwsA(isA<OpdsParseException>()),
      );
    });

    test('缺少标题的条目被跳过', () {
      final feed = OpdsParser.parse(
        _xml('''
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>T</title>
  <entry><id>1</id><link rel="subsection" href="/a"/></entry>
  <entry><title>B</title><id>2</id><link rel="subsection" href="/b"/></entry>
</feed>
'''),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.entries, hasLength(1));
      expect(feed.entries.single.title, 'B');
    });

    test('条目数超过上限时被截断', () {
      final buffer = StringBuffer(
        '<feed xmlns="http://www.w3.org/2005/Atom"><title>T</title>',
      );
      for (var i = 0; i < OpdsParser.maxEntries + 20; i++) {
        buffer.write(
          '<entry><title>E$i</title><id>$i</id>'
          '<link rel="subsection" href="/e$i"/></entry>',
        );
      }
      buffer.write('</feed>');

      final feed = OpdsParser.parse(
        _xml(buffer.toString()),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.entries, hasLength(OpdsParser.maxEntries));
    });

    test('单条目链接数超过上限时被截断', () {
      final buffer = StringBuffer(
        '<feed xmlns="http://www.w3.org/2005/Atom"><title>T</title>'
        '<entry><title>E</title><id>1</id>',
      );
      for (var i = 0; i < OpdsParser.maxLinksPerEntry + 10; i++) {
        buffer.write('<link rel="subsection" href="/l$i"/>');
      }
      buffer.write('</entry></feed>');

      final feed = OpdsParser.parse(
        _xml(buffer.toString()),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.entries.single.links, hasLength(OpdsParser.maxLinksPerEntry));
    });

    test('空 feed 不报错', () {
      final feed = OpdsParser.parse(
        _xml(
          '<feed xmlns="http://www.w3.org/2005/Atom"><title>T</title></feed>',
        ),
        baseUrl: Uri.parse(_base),
      );

      expect(feed.hasEntries, isFalse);
      expect(feed.kind, OpdsFeedKind.navigation);
    });
  });

  group('OpdsLink', () {
    test('relName 取最后一段', () {
      final link = OpdsLink(
        rel: 'http://opds-spec.org/image/thumbnail',
        href: _exampleUri,
      );
      expect(link.relName, 'thumbnail');
    });

    test('无斜杠的 rel 原样返回', () {
      final link = OpdsLink(
        rel: 'next',
        href: Uri.parse('https://example.org/a'),
      );
      expect(link.relName, 'next');
    });
  });
}
