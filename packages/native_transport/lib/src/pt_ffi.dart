/// The real (dart:ffi) branch of the conditional export in
/// `native_transport.dart`. Selected at compile time on every platform where
/// `dart.library.ffi` exists (VM/AOT: macOS, iOS, Android, Linux, Windows).
library;

export 'pt_bindings.dart' show PtBindings, PtSessionHandle;
export 'shim_probe.dart' show EchProbeOutcome, ShimProbe, ShimProbeState;
export 'pt_native_lane.dart' show PtNativeLane;
export 'pt_session.dart' show PtSession;

/// True on this branch: `dart:ffi` is available, so the native lane CAN be
/// compiled and used here.
///
/// Honesty note: this reports compile-time availability of the FFI mechanism
/// only. It does NOT promise that a `libpt_transport` library exists at any
/// particular path — `PtBindings.open` still fails, loudly, if the file the
/// caller names is absent or has the wrong architecture. This constant and the
/// loader can never disagree: the loader is the only thing that opens
/// libraries, and this constant claims nothing about any library.
const bool isNativeTransportAvailable = true;
