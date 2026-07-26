/// Unified connectivity fabric.
///
/// The one place that owns every way this device can move bytes: live
/// transport lanes ([TransportChannel]s from any package) and the
/// delay-tolerant bundle queue. Callers deliver through the fabric and
/// never care which lane carried the payload — or whether it had to wait.
library;

export 'src/carrier_relay.dart';
export 'src/chunked_transfer.dart';
export 'src/cold_start_dictionary.dart';
export 'src/connection_fabric.dart';
export 'src/connectivity_snapshot.dart';
export 'src/delivery_ledger.dart';
export 'src/delivery_planner.dart';
export 'src/gilbert_elliott_loss.dart';
export 'src/lane.dart';
export 'src/secure_media_lane.dart';
export 'src/lane_experience.dart';
export 'src/micro_learner.dart';
export 'src/media_carriage.dart';
export 'src/micro_datagram_lane.dart';
export 'src/resilient_media_transport.dart';
export 'src/silence_suppression_vad.dart';
export 'src/token_voice_channel.dart';
export 'src/trend_sentinel.dart';
export 'src/weak_link_codec.dart';
