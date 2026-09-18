/// Re-export of the promoted production implementation.
///
/// `DatagramLanePort` moved to `lib/src/datagram_lane_port.dart` (real
/// production code, not test-only support) — this file stays so every
/// existing `support/datagram_lane_port.dart` importer keeps working
/// unchanged.
library;

export 'package:reference_app/src/datagram_lane_port.dart';
