/// Log redaction.
///
/// Every log line in the app passes through [LogRedactor.redact] before it
/// reaches any sink (console, file, crash reporter). The redactor removes
/// or masks:
/// - IPv4 and IPv6 addresses (including those inside ICE candidate lines
///   and SDP `c=` / `a=candidate` fields);
/// - email addresses and international phone numbers;
/// - bearer tokens, long opaque secrets, and base64 key material;
/// - URI userinfo and query strings (which often carry credentials).
///
/// The output keeps enough shape for debugging (e.g. `[ipv4]`) without the
/// value. Rule of thumb encoded here: when in doubt, redact — a less useful
/// log is recoverable, a leaked address book is not.
///
/// Designed from the v2 blueprint role (no v1 equivalent).
library;

class _RedactionRule {
  final RegExp pattern;
  final String Function(Match) replace;

  _RedactionRule(this.pattern, this.replace);
}

class LogRedactor {
  static final List<_RedactionRule> _rules = [
    // URI credentials and queries first, before generic token rules eat
    // parts of them: scheme://user:pass@host/path?query -> scheme://[redacted-userinfo]@host/path?[redacted-query]
    _RedactionRule(
      RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*://)([^/@\s]+)@'),
      (m) => '${m[1]}[redacted-userinfo]@',
    ),
    _RedactionRule(RegExp(r'\?[^\s"]+'), (_) => '?[redacted-query]'),

    // Bearer / token-style credentials.
    _RedactionRule(
      RegExp(
        r'\b(bearer|token|authorization|password|secret|credential)\b'
        r'([=:\s]+)\S+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${m[2]}[redacted]',
    ),

    // Email addresses.
    _RedactionRule(
      RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'),
      (_) => '[email]',
    ),

    // IPv4, including in candidate lines and host:port forms. Runs before
    // the phone-number rule below so a dotted-quad (e.g. 192.168.1.42)
    // is never mislabeled as a phone number.
    _RedactionRule(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), (_) => '[ipv4]'),

    // IPv6 (compressed and full forms), bracketed or bare. Also runs
    // before the phone-number rule for the same reason.
    _RedactionRule(
      RegExp(r'\[?\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{0,4}\b\]?'),
      (_) => '[ipv6]',
    ),

    // International phone numbers (7+ digits, optional +, separators).
    // Excludes '.' from the separator class so a dotted-quad IPv4 address
    // can never match here (it is already redacted by the IPv4 rule
    // above); real phone formats like "+49 (30) 1234-5678" still match
    // via spaces, parens, and hyphens.
    _RedactionRule(RegExp(r'\+?\d[\d\s()-]{6,}\d'), (_) => '[phone]'),

    // Long base64/hex blobs (32+ chars): keys, signatures, session ids.
    _RedactionRule(RegExp(r'\b[A-Za-z0-9+/_-]{32,}={0,2}\b'), (_) => '[blob]'),
  ];

  /// Returns a redacted copy of [line]. Never throws: on any internal
  /// error the whole line is replaced, because failing open would leak.
  static String redact(String line) {
    try {
      var result = line;
      for (final rule in _rules) {
        result = result.replaceAllMapped(rule.pattern, rule.replace);
      }
      return result;
    } catch (_) {
      return '[redaction-failure: line dropped]';
    }
  }

  /// Redacts an SDP body more aggressively than free-form logs: connection
  /// and candidate lines are summarized instead of printed.
  static String redactSdp(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    final out = <String>[];
    var candidateCount = 0;
    for (final line in lines) {
      if (line.startsWith('a=candidate')) {
        candidateCount++;
        continue;
      }
      if (line.startsWith('c=')) {
        out.add('c=[redacted-connection]');
        continue;
      }
      // Keep structural lines (m=, a=mid, codecs) after generic redaction.
      out.add(redact(line));
    }
    if (candidateCount > 0) {
      out.add('a=[${candidateCount} candidate lines redacted]');
    }
    return out.join('\n');
  }
}

/// Log severity for [RedactingLogger].
enum LogLevel { debug, info, warning, error }

/// Sink receiving already-redacted lines.
typedef LogSink = void Function(LogLevel level, String redactedMessage);

/// Convenience logger that guarantees redaction before the sink. Inject
/// this everywhere instead of `print`.
class RedactingLogger {
  final LogSink _sink;
  final LogLevel minimumLevel;

  const RedactingLogger(this._sink, {this.minimumLevel = LogLevel.info});

  void debug(String message) => _log(LogLevel.debug, message);
  void info(String message) => _log(LogLevel.info, message);
  void warning(String message) => _log(LogLevel.warning, message);
  void error(String message) => _log(LogLevel.error, message);

  void _log(LogLevel level, String message) {
    if (level.index < minimumLevel.index) return;
    _sink(level, LogRedactor.redact(message));
  }
}
