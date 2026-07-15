class HostPort {
  final String host;
  final int port;

  const HostPort({
    required this.host,
    required this.port,
  });

  factory HostPort.fromJson(Map<String, Object?> json) {
    final host = json['host'];
    final port = json['port'];

    if (host is! String || host.trim().isEmpty) {
      throw const FormatException(
        'Endpoint host must be a non-empty string.',
      );
    }

    if (port is! int || port < 1 || port > 65535) {
      throw const FormatException(
        'Endpoint port must be an integer from 1 to 65535.',
      );
    }

    return HostPort(
      host: host.trim(),
      port: port,
    );
  }

  /// Accepts:
  /// - example.org:443
  /// - 192.0.2.10:443
  /// - [2001:db8::10]:443
  ///
  /// Unbracketed IPv6 authorities are rejected because their port is
  /// ambiguous.
  factory HostPort.parseAuthority(String input) {
    final value = input.trim();

    if (value.isEmpty) {
      throw const FormatException('Endpoint authority is empty.');
    }

    if (value.contains('://')) {
      throw const FormatException(
        'Expected host:port authority, not a full URI.',
      );
    }

    final colonCount = ':'.allMatches(value).length;

    if (colonCount > 1 && !value.startsWith('[')) {
      throw const FormatException(
        'IPv6 addresses with a port must use bracket notation, '
        'for example [2001:db8::1]:443.',
      );
    }

    final uri = Uri.tryParse('tcp://$value');

    if (uri == null ||
        uri.host.isEmpty ||
        !uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw FormatException('Invalid endpoint authority: $input');
    }

    if (uri.port < 1 || uri.port > 65535) {
      throw FormatException('Invalid endpoint port: ${uri.port}');
    }

    return HostPort(
      host: uri.host,
      port: uri.port,
    );
  }

  String get authority {
    final formattedHost =
        host.contains(':') ? '[$host]' : host;

    return '$formattedHost:$port';
  }

  Uri toUri(String scheme) {
    if (scheme.isEmpty) {
      throw ArgumentError.value(scheme, 'scheme');
    }

    return Uri(
      scheme: scheme,
      host: host,
      port: port,
    );
  }

  Map<String, Object> toJson() => {
        'host': host,
        'port': port,
      };

  @override
  String toString() => authority;
}
