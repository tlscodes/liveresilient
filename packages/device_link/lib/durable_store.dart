/// Opt-in disk-backed persistence for [DtnBundleQueue]. Imports `dart:io`,
/// so it is a separate entry point from the neutral `device_link.dart`
/// barrel — import this only on platforms with a filesystem.
library;

export 'src/durable_bundle_store.dart';
