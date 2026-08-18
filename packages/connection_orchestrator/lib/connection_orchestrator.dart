/// Unified connectivity fabric.
///
/// The one place that owns every way this device can move bytes: live
/// transport lanes ([TransportChannel]s from any package) and the
/// delay-tolerant bundle queue. Callers deliver through the fabric and
/// never care which lane carried the payload — or whether it had to wait.
library;

export 'src/blind_channel_estimator.dart';
export 'src/brain_generations.dart';
export 'src/budget_calibrator.dart';
export 'src/call_history.dart';
export 'src/carrier_relay.dart';
export 'src/attachment_route_advisor.dart';
export 'src/cliff_free_inbox.dart';
export 'src/cliff_free_media_sender.dart';
export 'src/cliff_free_reassembler.dart';
export 'src/media_send_router.dart';
export 'src/gf256_rlnc_stream.dart';
export 'src/layered_redundancy_allocator.dart';
export 'src/rlnc_probe_carrier.dart';
export 'src/chunked_transfer.dart';
export 'src/cold_start_dictionary.dart';
export 'src/connection_fabric.dart';
export 'src/connectivity_snapshot.dart';
export 'src/delivery_ledger.dart';
export 'src/delivery_planner.dart';
export 'src/gilbert_elliott_loss.dart';
export 'src/lane.dart';
export 'src/secure_media_lane.dart';
export 'src/lane_choice_policy.dart';
export 'src/lane_experience.dart';
export 'src/measurement_journal.dart';
export 'src/micro_learner.dart';
export 'src/network_atlas.dart';
export 'src/cliff_free_batch.dart';
export 'src/media_carriage.dart';
// `MediaCarriage.wrap` takes a `TaggedDatagram` and `media_carriage.dart` is
// exported, so the barrel published a method whose PARAMETER TYPE could not be
// named from outside the package: no other package could construct an argument
// for it. That is not a style problem — it is why the cliff-free path has never
// crossed the carrier in any test outside this package, and an API nobody can
// call accumulates no evidence that it works.
export 'src/media_queue.dart' show TaggedDatagram;
// The media codecs were internal while only `resilient_media_transport`
// used them. They are exported now because the broadcast layer encodes
// its payloads with the same ones, and two copies of a codec is two
// codecs to keep bit-compatible.
export 'src/media_codecs/flipbook_video_compressor.dart';
export 'src/media_codecs/live_context_compressor.dart';
export 'src/media_codecs/low_rate_image_compressor.dart';
export 'src/media_codecs/media_frontends.dart';
export 'src/media_codecs/text_document_compressor.dart';
export 'src/micro_datagram_lane.dart';
export 'src/rateless_stream.dart';
export 'src/replay_benchmark.dart';
export 'src/resilient_fallback_lanes.dart';
export 'src/resilient_media_transport.dart';
export 'src/silence_suppression_vad.dart';
export 'src/token_voice_channel.dart';
export 'src/trend_monitor.dart';
export 'src/weak_link_codec.dart';
export 'src/wire_trace_recorder.dart';
