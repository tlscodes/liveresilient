/// Signed one-to-many publishing for readers on hostile networks.
///
/// The shape of this package, in one paragraph: a post is a small signed
/// *descriptor* that commits to the hash of each of its layers, and
/// nothing else. Layers are fetched independently, by content hash, from
/// any number of interchangeable relays. A reader follows an author by
/// asking for sequence numbers it can predict, so there is no mutable
/// "latest" pointer to block and no recipient list to leak. Posts are
/// signed by a short-lived publishing key delegated from a long-lived
/// identity key, so a lost device stops being able to speak for the
/// author on its own.
///
/// What this package does NOT provide, stated here because getting it
/// wrong in a user interface would be worse than not having it: public
/// broadcast is not confidential. If a million people can read a post,
/// so can anyone watching. Authenticity and availability are the
/// guarantees; secrecy is not one of them, and this must never share a
/// surface with private messaging.
library;

export 'src/bootstrap_code.dart';
export 'src/broadcast_address.dart';
export 'src/broadcast_chain.dart';
export 'src/broadcast_descriptor.dart';
export 'src/broadcast_fanout.dart';
export 'src/broadcast_ids.dart';
export 'src/broadcast_keys.dart';
export 'src/broadcast_publisher.dart';
export 'src/broadcast_reader.dart';
export 'src/broadcast_relay.dart';
export 'src/fork_report.dart';
export 'src/http_broadcast_relay.dart';
export 'src/layer_hash_list.dart';
export 'src/publishing_key_certificate.dart';
export 'src/relay_directory.dart';
