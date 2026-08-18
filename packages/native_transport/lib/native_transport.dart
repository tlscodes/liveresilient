/// Optional binding to the pluggable-transport C core.
///
/// Nothing in the product depends on this package. It is loaded explicitly, by
/// path, by a caller that has decided to use it.
///
/// WEB SAFETY. `dart:ffi` does not exist on the web, so the native pieces are
/// selected by a conditional export: platforms with `dart.library.ffi` get the
/// real bindings; the web gets same-shaped stubs that throw [UnsupportedError]
/// on use. Check [isNativeTransportAvailable] (a compile-time constant on both
/// branches) and degrade to the pure-Dart lanes when it is false — the pure
/// packages (quality_governor, seed_lineage, ...) never depend on this one.
library;

export 'src/pt_common.dart' show PtException, PtStatus, ptNativeLaneName;
export 'src/pt_ffi.dart'
    if (dart.library.js_interop) 'src/pt_unavailable.dart'
    show
        PtBindings,
        PtNativeLane,
        PtSession,
        PtSessionHandle,
        EchProbeOutcome,
        ShimProbe,
        ShimProbeState,
        isNativeTransportAvailable;
