/// Meeting point of the messaging layer and the call's data channel.
///
/// messaging defines an abstract DataChannelPort and never names a
/// transport; media_webrtc produces MediaDataChannel and never names a
/// consumer. This package is the single place allowed to know both — the
/// exact pattern call_signaling_adapter establishes for the signaling side.
library;

export 'src/media_channel_data_port.dart';
