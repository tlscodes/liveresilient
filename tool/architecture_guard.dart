import 'dart:io';

class ForbiddenPattern {
  final String description;
  final RegExp pattern;

  const ForbiddenPattern(this.description, this.pattern);
}

void main() {
  final forbiddenPatterns = <ForbiddenPattern>[
    ForbiddenPattern(
      'Embedded sing-box dependency or import',
      RegExp(r'\bsing[-_]?box\b', caseSensitive: false),
    ),
    ForbiddenPattern(
      'Embedded VLESS transport configuration',
      RegExp(r'\bvless\b', caseSensitive: false),
    ),
    ForbiddenPattern(
      'Legacy Reality transport configuration',
      RegExp(r'\bRealityOptions\b|\brealityConfig\b', caseSensitive: false),
    ),
    ForbiddenPattern(
      'Legacy front-domain configuration',
      RegExp(r'\bfrontDomain\b', caseSensitive: true),
    ),
    ForbiddenPattern(
      'Legacy traffic-obfuscation profile',
      RegExp(r'\bObfuscationProfile\b', caseSensitive: true),
    ),
    ForbiddenPattern(
      'Manual Host-header override',
      RegExp(r'''headers\s*\[\s*['"]Host['"]\s*\]''', caseSensitive: false),
    ),
    ForbiddenPattern(
      'Legacy TLS fragmentation/padding setting',
      RegExp(r'\btlsFragment\b|\btlsPadding\b', caseSensitive: false),
    ),
  ];

  final workspaceRoot = _findWorkspaceRoot();

  final roots = <String>[];
  final packagesDir = Directory('${workspaceRoot.path}/packages');
  if (packagesDir.existsSync()) {
    for (final entity in packagesDir.listSync(followLinks: false)) {
      if (entity is Directory) {
        roots.add('${entity.path}/lib');
        roots.add('${entity.path}/android/app/src');
        roots.add('${entity.path}/ios/Runner');
      }
    }
  }
  final appsDir = Directory('${workspaceRoot.path}/apps');
  if (appsDir.existsSync()) {
    for (final entity in appsDir.listSync(followLinks: false)) {
      if (entity is Directory) {
        roots.add('${entity.path}/lib');
        roots.add('${entity.path}/android/app/src');
        roots.add('${entity.path}/ios/Runner');
      }
    }
  }

  final explicitFiles = <String>[
    '${workspaceRoot.path}/pubspec.yaml',
    '${workspaceRoot.path}/pubspec.lock',
  ];

  final violations = <String>[];
  var scannedFileCount = 0;

  for (final rootPath in roots) {
    final root = Directory(rootPath);

    if (!root.existsSync()) {
      continue;
    }

    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !_shouldScan(entity.path)) {
        continue;
      }

      scannedFileCount++;
      _scanFile(entity, forbiddenPatterns, violations);
    }
  }

  for (final path in explicitFiles) {
    final file = File(path);

    if (file.existsSync()) {
      scannedFileCount++;
      _scanFile(file, forbiddenPatterns, violations);
    }
  }

  stdout.writeln('Architecture guard scanned $scannedFileCount file(s).');

  if (scannedFileCount == 0) {
    stderr.writeln(
      'Architecture guard failed: scanned zero files. '
      'Workspace root resolved to "${workspaceRoot.path}" — '
      'a guard that checks nothing must fail loudly, not pass silently.',
    );
    exitCode = 1;
    return;
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

/// Locates the monorepo workspace root by walking up from the script
/// location (falling back to the current directory) until a directory is
/// found that either has a `pubspec.yaml` declaring a `workspace:` member
/// list, or simply contains a `packages/` folder.
Directory _findWorkspaceRoot() {
  Directory start;
  try {
    start = File(Platform.script.toFilePath()).parent;
  } catch (_) {
    start = Directory.current;
  }

  Directory? candidate = start.absolute;

  while (candidate != null) {
    final pubspec = File('${candidate.path}/pubspec.yaml');
    if (pubspec.existsSync()) {
      final content = pubspec.readAsStringSync();
      if (RegExp(r'^\s*workspace\s*:', multiLine: true).hasMatch(content)) {
        return candidate;
      }
    }

    if (Directory('${candidate.path}/packages').existsSync()) {
      return candidate;
    }

    final parent = candidate.parent;
    if (parent.path == candidate.path) {
      break;
    }
    candidate = parent;
  }

  // Nothing matched: fall back to the current directory so the caller
  // still gets a deterministic (if empty) scan rather than a crash.
  return Directory.current.absolute;
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
