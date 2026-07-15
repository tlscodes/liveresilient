import 'dart:io';

class ForbiddenPattern {
  final String description;
  final RegExp pattern;

  const ForbiddenPattern(
    this.description,
    this.pattern,
  );
}

void main() {
  final forbiddenPatterns = <ForbiddenPattern>[
    ForbiddenPattern(
      'Embedded sing-box dependency or import',
      RegExp(
        r'\bsing[-_]?box\b',
        caseSensitive: false,
      ),
    ),
    ForbiddenPattern(
      'Embedded VLESS transport configuration',
      RegExp(
        r'\bvless\b',
        caseSensitive: false,
      ),
    ),
    ForbiddenPattern(
      'Legacy Reality transport configuration',
      RegExp(
        r'\bRealityOptions\b|\brealityConfig\b',
        caseSensitive: false,
      ),
    ),
    ForbiddenPattern(
      'Legacy front-domain configuration',
      RegExp(
        r'\bfrontDomain\b',
        caseSensitive: true,
      ),
    ),
    ForbiddenPattern(
      'Legacy traffic-obfuscation profile',
      RegExp(
        r'\bObfuscationProfile\b',
        caseSensitive: true,
      ),
    ),
    ForbiddenPattern(
      'Manual Host-header override',
      RegExp(
        r'''headers\s*\[\s*['"]Host['"]\s*\]''',
        caseSensitive: false,
      ),
    ),
    ForbiddenPattern(
      'Legacy TLS fragmentation/padding setting',
      RegExp(
        r'\btlsFragment\b|\btlsPadding\b',
        caseSensitive: false,
      ),
    ),
  ];

  final roots = <String>[
    'lib',
    'android/app/src',
    'ios/Runner',
  ];

  final explicitFiles = <String>[
    'pubspec.yaml',
    'pubspec.lock',
  ];

  final violations = <String>[];

  for (final rootPath in roots) {
    final root = Directory(rootPath);

    if (!root.existsSync()) {
      continue;
    }

    for (final entity in root.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !_shouldScan(entity.path)) {
        continue;
      }

      _scanFile(
        entity,
        forbiddenPatterns,
        violations,
      );
    }
  }

  for (final path in explicitFiles) {
    final file = File(path);

    if (file.existsSync()) {
      _scanFile(
        file,
        forbiddenPatterns,
        violations,
      );
    }
  }

  if (violations.isEmpty) {
    stdout.writeln(
      'Architecture guard passed: no excluded legacy '
      'transport components were found.',
    );
    return;
  }

  stderr.writeln('Architecture guard failed:');

  for (final violation in violations) {
    stderr.writeln('  - $violation');
  }

  stderr.writeln();
  stderr.writeln(
    'The v2 core must remain standards-based. '
    'Review the reported source or dependency.',
  );

  exitCode = 1;
}

bool _shouldScan(String path) {
  final normalized = path.replaceAll('\\', '/');

  if (normalized.contains('/build/') ||
      normalized.contains('/.dart_tool/') ||
      normalized.contains('/Pods/')) {
    return false;
  }

  return normalized.endsWith('.dart') ||
      normalized.endsWith('.kt') ||
      normalized.endsWith('.java') ||
      normalized.endsWith('.swift') ||
      normalized.endsWith('.m') ||
      normalized.endsWith('.mm') ||
      normalized.endsWith('.xml') ||
      normalized.endsWith('.plist') ||
      normalized.endsWith('.gradle');
}

void _scanFile(
  File file,
  List<ForbiddenPattern> patterns,
  List<String> violations,
) {
  final lines = file.readAsLinesSync();

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];

    for (final forbidden in patterns) {
      if (forbidden.pattern.hasMatch(line)) {
        violations.add(
          '${file.path}:${index + 1}: '
          '${forbidden.description}',
        );
      }
    }
  }
}
