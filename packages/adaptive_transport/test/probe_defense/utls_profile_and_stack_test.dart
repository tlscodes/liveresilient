import 'dart:math';
import 'dart:typed_data';

import 'package:adaptive_transport/adaptive_transport.dart';
import 'package:test/test.dart';

TlsClientHello _hello(UtlsClientProfile profile, {bool enableEch = false}) {
  final builder = UtlsClientHelloBuilder(profile: profile, random: Random(4));
  return TlsClientHello.parseHandshake(
    builder.build(serverName: 'www.example.com', enableEch: enableEch),
  );
}

void main() {
  group('UtlsClientProfile invariants', () {
    test('Firefox sends no GREASE — adding it would create the anomaly', () {
      final hello = _hello(UtlsClientProfile.firefox120);
      expect(hello.cipherSuites.any(isGreaseCodePoint), isFalse);
      expect(hello.extensions.map((e) => e.type).any(isGreaseCodePoint),
          isFalse);
      expect(hello.supportedGroups.any(isGreaseCodePoint), isFalse);
    });

    test('Chrome and Safari open and close with GREASE', () {
      for (final profile in [
        UtlsClientProfile.chrome120,
        UtlsClientProfile.safari17,
      ]) {
        final hello = _hello(profile);
        expect(hello.cipherSuites.first, predicate<int>(isGreaseCodePoint),
            reason: profile.id.name);
        expect(hello.extensions.map((e) => e.type).where(isGreaseCodePoint),
            hasLength(2),
            reason: profile.id.name);
      }
    });

    test('Chrome and Firefox offer the hybrid post-quantum group', () {
      for (final profile in [
        UtlsClientProfile.chrome120,
        UtlsClientProfile.firefox120,
      ]) {
        expect(profile.offersPostQuantum, isTrue, reason: profile.id.name);
        final hello = _hello(profile);
        expect(hello.supportedGroups, contains(TlsNamedGroup.x25519MlKem768));
        expect(hello.keyShareGroups, contains(TlsNamedGroup.x25519MlKem768));
      }
    });

    test('Safari 17 does not — claiming Safari with ML-KEM would be a tell',
        () {
      final profile = UtlsClientProfile.safari17;
      expect(profile.offersPostQuantum, isFalse);
      expect(_hello(profile).supportedGroups.any(TlsNamedGroup.isPostQuantum),
          isFalse);
    });

    test('the hybrid key share is the full X25519 + ML-KEM-768 size', () {
      final builder = UtlsClientHelloBuilder(
        profile: UtlsClientProfile.chrome120,
        random: Random(4),
      );
      final bytes = builder.build(serverName: 'www.example.com');
      final hello = TlsClientHello.parseHandshake(bytes);
      final keyShare = hello.extension(TlsExtensionType.keyShare)!;
      // 32 bytes of X25519 plus the 1184-byte ML-KEM-768 encapsulation key.
      expect(TlsNamedGroup.keyShareLength(TlsNamedGroup.x25519MlKem768), 1216);
      // The extension is large precisely because of that share — the size
      // itself is part of the signature.
      expect(keyShare.data.length, greaterThan(1216));
    });

    test('a supplied real key share is carried through verbatim', () {
      final share = Uint8List.fromList(
        List<int>.generate(1216, (i) => (i * 7) & 0xFF),
      );
      final builder = UtlsClientHelloBuilder(
        profile: UtlsClientProfile.chrome120,
        random: Random(4),
      );
      final hello = TlsClientHello.parseHandshake(builder.build(
        serverName: 'www.example.com',
        keyShares: {TlsNamedGroup.x25519MlKem768: share},
      ));
      final data = hello.extension(TlsExtensionType.keyShare)!.data;
      expect(_containsSubsequence(data, share), isTrue);
    });

    test('every profile offers TLS 1.3 and both ALPN protocols', () {
      for (final profile in UtlsClientProfile.all) {
        final hello = _hello(profile);
        expect(hello.supportedVersions, contains(0x0304),
            reason: profile.id.name);
        expect(hello.alpnProtocols, ['h2', 'http/1.1'],
            reason: profile.id.name);
      }
    });

    test('Firefox advertises record_size_limit and the others do not', () {
      expect(
        _hello(UtlsClientProfile.firefox120)
            .extension(TlsExtensionType.recordSizeLimit),
        isNotNull,
      );
      expect(
        _hello(UtlsClientProfile.chrome120)
            .extension(TlsExtensionType.recordSizeLimit),
        isNull,
      );
    });

    test('ECH is emitted when asked for, and absent otherwise', () {
      expect(_hello(UtlsClientProfile.chrome120).hasEncryptedClientHello,
          isFalse);
      final withEch = _hello(UtlsClientProfile.chrome120, enableEch: true);
      expect(withEch.hasEncryptedClientHello, isTrue);
      final payload =
          withEch.extension(TlsExtensionType.encryptedClientHello)!.data;
      expect(payload.first, 0x00, reason: 'outer_client_hello');
      expect(payload.length, greaterThan(190),
          reason: 'a GREASE ECH must be the size of a real one');
    });

    test('padding brings a hello up to the requested length', () {
      final builder = UtlsClientHelloBuilder(
        profile: UtlsClientProfile.chrome120,
        random: Random(4),
      );
      final padded =
          builder.build(serverName: 'www.example.com', padToLength: 1700);
      expect(padded.length, 1700);
      expect(
        TlsClientHello.parseHandshake(padded).serverName,
        'www.example.com',
      );
      expect(
        TlsClientHello.parseHandshake(padded)
            .extension(TlsExtensionType.padding),
        isNotNull,
      );
    });

    test('a target below the natural size leaves the hello alone rather '
        'than truncating it', () {
      final builder = UtlsClientHelloBuilder(
        profile: UtlsClientProfile.chrome120,
        random: Random(4),
      );
      final natural = builder.build(serverName: 'www.example.com');
      final asked = UtlsClientHelloBuilder(
        profile: UtlsClientProfile.chrome120,
        random: Random(4),
      ).build(serverName: 'www.example.com', padToLength: 128);
      expect(asked.length, natural.length);
    });

    test('every profile names a TCP stack that exists', () {
      for (final profile in UtlsClientProfile.all) {
        expect(TcpStackProfile.byName(profile.defaultTcpProfile), isNotNull,
            reason: profile.id.name);
      }
    });
  });

  group('TcpStackProfile', () {
    test('carries the classic initial-TTL tells', () {
      expect(TcpStackProfile.windows.initialTtl, 128);
      expect(TcpStackProfile.iOS.initialTtl, 64);
      expect(TcpStackProfile.linux.initialTtl, 64);
      expect(TcpStackProfile.android.initialTtl, 64);
    });

    test('renders a p0f-style signature', () {
      expect(TcpStackProfile.windows.p0fSignature, '128:64240,8:mss=1460:sok,-');
      expect(TcpStackProfile.iOS.p0fSignature, '64:65535,6:mss=1460:sok,ts');
    });

    test('is honest about what a userspace process cannot set', () {
      for (final profile in TcpStackProfile.all) {
        final gaps = profile.unreachableObservables;
        expect(gaps, isNotEmpty,
            reason: 'no platform lets a VM set every SYN observable');
        expect(gaps, contains('window_scale'));
        expect(gaps, contains('option_order'));
      }
    });

    test('resolves by name, case-insensitively', () {
      expect(TcpStackProfile.byName('ios')?.id, TcpStackProfileId.iOS);
      expect(TcpStackProfile.byName('Windows')?.id, TcpStackProfileId.windows);
      expect(TcpStackProfile.byName('plan9'), isNull);
    });
  });

  group('ProbeDefenseConfig', () {
    test('defaults the TCP stack to the one its TLS profile implies', () {
      expect(
        ProbeDefenseConfig(utlsProfile: UtlsProfileId.safari17,
                enablePostQuantum: false)
            .tcpProfile,
        TcpStackProfileId.iOS,
      );
      expect(
        ProbeDefenseConfig(utlsProfile: UtlsProfileId.firefox120).tcpProfile,
        TcpStackProfileId.linux,
      );
    });

    test('rejects a Safari hello over a Windows stack', () {
      expect(
        () => ProbeDefenseConfig(
          utlsProfile: UtlsProfileId.safari17,
          tcpProfile: TcpStackProfileId.windows,
          enablePostQuantum: false,
        ),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
    });

    test('allows a deliberate mismatch when the host OS really differs', () {
      final config = ProbeDefenseConfig(
        utlsProfile: UtlsProfileId.safari17,
        tcpProfile: TcpStackProfileId.windows,
        enablePostQuantum: false,
        allowProfileMismatch: true,
      );
      expect(config.tcpProfile, TcpStackProfileId.windows);
    });

    test('rejects post-quantum on a profile that ships none', () {
      expect(
        () => ProbeDefenseConfig(utlsProfile: UtlsProfileId.safari17),
        throwsA(isA<ProbeDefenseConfigError>()),
      );
    });

    test('accepts post-quantum on Chrome, the default posture', () {
      final config = ProbeDefenseConfig();
      expect(config.enablePostQuantum, isTrue);
      expect(config.tls.offersPostQuantum, isTrue);
      expect(config.tcpProfile, TcpStackProfileId.windows);
      expect(config.unenforceableObservables, isNotEmpty);
    });
  });
}

bool _containsSubsequence(Uint8List haystack, Uint8List needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
