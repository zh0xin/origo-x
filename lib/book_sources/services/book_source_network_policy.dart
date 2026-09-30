import 'dart:async';
import 'dart:io';

import '../protocol/book_source_protocol.dart';

typedef BookSourceAddressLookup =
    Future<List<InternetAddress>> Function(String host);

class BookSourceNetworkPolicy {
  const BookSourceNetworkPolicy({
    BookSourceAddressLookup? lookup,
    this.allowPrivateNetwork = false,
    this.allowSyntheticDns = false,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  final BookSourceAddressLookup _lookup;
  final bool allowPrivateNetwork;
  final bool allowSyntheticDns;

  Future<void> validate(Uri uri) async {
    await resolve(uri);
  }

  Future<List<InternetAddress>> resolve(Uri uri) async {
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'Book source targets must use HTTP or HTTPS.',
      );
    }
    final literal = InternetAddress.tryParse(uri.host);
    final addresses = literal == null ? await _lookup(uri.host) : [literal];
    if (addresses.isEmpty ||
        addresses.any(
          (address) =>
              _isAlwaysBlockedAddress(address) ||
              (!allowPrivateNetwork &&
                  isBlockedAddress(
                    address,
                    allowSyntheticDns: allowSyntheticDns,
                  )),
        )) {
      throw const BookSourceProtocolException(
        'This address is not allowed as a book source target.',
      );
    }
    return addresses;
  }

  HttpClient createPinnedHttpClient() {
    final client = HttpClient();
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final targetHost = proxyHost ?? uri.host;
      final targetPort = proxyPort ?? uri.port;
      final targetUri = proxyHost == null
          ? uri
          : Uri(scheme: 'http', host: targetHost, port: targetPort);
      // 先做 SSRF 校验（解析 + 私网/回环拦截），并在需要时选出可达地址。
      final addresses = await resolve(targetUri);

      // 直连 HTTPS 时，connectionFactory 必须返回“已完成 TLS 握手”的套接字：
      // dart:io 对经由 connectionFactory 得到的 socket 不会再自动叠加 TLS
      // （http_impl 的 factory + direct 分支直接把原始 socket 当作连接使用）。
      // 若这里返回明文 Socket，就等于把明文 HTTP 发到 TLS 端口，服务器随即断开，
      // 表现为 “Connection closed before full header was received”。
      // 用主机名建立 SecureSocket，以获得正确的 SNI 与证书校验
      // （同时原生支持 IPv4/IPv6 双栈回退）；上面的 resolve() 已完成私网/SSRF 拦截。
      if (proxyHost == null && uri.isScheme('https')) {
        return SecureSocket.startConnect(uri.host, targetPort);
      }

      // HTTP（或经代理，由 dart:io 负责隧道内的 TLS）：绑定到已校验的 IP。
      final target = await _firstReachableAddress(addresses, targetPort);
      return Socket.startConnect(target, targetPort);
    };
    return client;
  }

  /// 从已通过校验的地址列表中选出首个可连通者。
  ///
  /// 主机名解析到多个地址（IPv4/IPv6 双栈很常见）时，仅连第一个且不回退，
  /// 会在首选地址不可达时直接失败：例如 DDNS 域名同时给出公网 IPv4 与 IPv6，
  /// 局域网内公网 IPv4 需路由器 NAT 回环（多数不支持）而 IPv6 可直连——
  /// 此时应回退到可达的那个地址，而非放弃。列表里的地址都已经过 resolve() 校验，
  /// 逐个探测不会绕过 SSRF 防护。
  ///
  /// 单地址时（绝大多数场景）不做任何探测，行为与直接连接完全一致。
  static Future<InternetAddress> _firstReachableAddress(
    List<InternetAddress> addresses,
    int targetPort,
  ) async {
    for (var i = 0; i < addresses.length; i++) {
      // 最后一个地址不再探测：直接返回，让真正的建连阶段抛出原始错误。
      if (i == addresses.length - 1) return addresses[i];
      try {
        final probe = await Socket.connect(
          addresses[i],
          targetPort,
          timeout: const Duration(seconds: 6),
        );
        probe.destroy();
        return addresses[i];
      } catch (_) {
        // 该地址不可达，尝试下一个。
      }
    }
    return addresses.first;
  }

  static bool isBlockedAddress(
    InternetAddress address, {
    bool allowSyntheticDns = false,
  }) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }

    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return _isBlockedIpv4(bytes, allowSyntheticDns: allowSyntheticDns);
    }
    if (bytes.length != 16) return true;

    // IPv4-mapped IPv6 addresses must inherit the IPv4 restrictions.
    final isIpv4Mapped =
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isIpv4Mapped) {
      return _isBlockedIpv4(
        bytes.sublist(12),
        allowSyntheticDns: allowSyntheticDns,
      );
    }

    // Unspecified, loopback, and unique-local (fc00::/7) addresses.
    if (bytes.every((byte) => byte == 0) ||
        (bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1) ||
        (bytes[0] & 0xfe) == 0xfc) {
      return true;
    }
    return false;
  }

  static bool _isAlwaysBlockedAddress(InternetAddress address) {
    if (address.isMulticast) return true;
    final bytes = address.rawAddress;
    if (bytes.every((byte) => byte == 0)) return true;
    return bytes.length == 4 && bytes[0] >= 224;
  }

  static bool _isBlockedIpv4(
    List<int> bytes, {
    bool allowSyntheticDns = false,
  }) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && (second & 0xc0) == 0x40) ||
        (first == 169 && second == 254) ||
        (first == 172 && (second & 0xf0) == 16) ||
        (first == 192 && second == 168) ||
        (!allowSyntheticDns &&
            first == 198 &&
            (second == 18 || second == 19)) ||
        first >= 224;
  }

  static Uri redirectTarget(Uri current, String? location) {
    if (location == null || location.trim().isEmpty) {
      throw const BookSourceProtocolException(
        'Book source redirect is missing its target.',
      );
    }
    final target = current.resolve(location.trim());
    if (target.scheme != 'http' && target.scheme != 'https') {
      throw const BookSourceProtocolException(
        'Book source redirects must use HTTP or HTTPS.',
      );
    }
    if (current.scheme == 'https' && target.scheme == 'http') {
      throw const BookSourceProtocolException(
        'Book source redirects cannot downgrade HTTPS to HTTP.',
      );
    }
    return target;
  }
}
