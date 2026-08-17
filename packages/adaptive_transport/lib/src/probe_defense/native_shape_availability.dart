/// Whether the native first-record capability is available — as a value with
/// exactly one possible answer today.
///
/// WHY A ONE-MEMBER TYPE INSTEAD OF AN INTERFACE. The capability needs a native
/// module that has never been linked, so nothing of it exists. Two designs were
/// rejected in review before this one (`docs/PLAN_five_tickets_v4.md:728-765`):
/// an optional seam with an implicit fall-back to ordinary behaviour, which is
/// the pattern that already died silently once in this repository, and a
/// mandatory choice between two named implementations, where the second is an
/// empty body delegating to ordinary behaviour. The second is worse than the
/// first: a reader six months later sees two named implementations and a journal
/// recording which was selected, and concludes the capability is built and
/// merely switched off.
///
/// So the absent capability is not modelled as an implementation at all. It is a
/// sealed status with one member, and the available state is UNREPRESENTABLE —
/// not merely unselected. A factory has nothing to construct; a test fixture has
/// nothing to fake; a screen has nothing to claim.
///
/// THE DAY THE MODULE WORKS, adding the second member is a deliberate, dated act
/// and it breaks every consumer at compile time through exhaustiveness. That
/// forced review of every consumption point is the entire mechanism — it is what
/// the rejected designs were reaching for and could not get.
library;

/// The status. Sealed with a private constructor: no code outside this library
/// can add a member, so the one-member claim is enforced rather than documented.
sealed class NativeShapeAvailability {
  const NativeShapeAvailability._();
}

/// The only member. Carries WHY, because "absent" with no cause invites a caller
/// to guess, and the guesses are exactly the false claims this file prevents.
final class NativeShapeAbsent extends NativeShapeAvailability {
  const NativeShapeAbsent(this.cause) : super._();

  final NativeShapeAbsentCause cause;

  @override
  String toString() => 'NativeShapeAbsent(${cause.name})';
}

/// Named causes, not a free-form string: a string field would let a caller
/// write anything, including something that reads like availability.
///
/// Every member is a reason the capability is absent. There is deliberately no
/// member meaning "available" — that is what the type system is for here, and
/// adding one would move the claim out of the sealed type and back into a field.
enum NativeShapeAbsentCause {
  /// No native module is linked into this build. The only cause reachable today.
  noModuleLinked,

  /// A module is linked and a run-time probe asked it; it reported that it
  /// cannot compose the first record itself.
  moduleReportedUnavailable,

  /// A module is linked, a run-time probe reported success, and the answer is
  /// STILL absent — because no available state exists in this type yet.
  ///
  /// This is not a defensive branch, it is the honesty of the design made
  /// visible: the day the probe can succeed, someone must add the second member
  /// and every consumer must be revisited. Until that happens, a successful
  /// probe is recorded as absent-with-this-cause rather than silently upgraded,
  /// so the gap is loud in the value instead of quiet in a comment.
  probeSucceededButPresentStateNotRepresentable,
}

/// What a run-time probe of the linked module reported.
///
/// A probe means: the module was asked, at run time, on this device, whether it
/// can compose the first handshake record. It is not a build flag, not a
/// platform check and not a version string.
enum NativeShapeProbeOutcome {
  /// Nothing is linked, so there was nothing to ask. Reachable today; the other
  /// two are not, and are here because the resolver's rule has to be written
  /// before the module arrives, not after.
  noModuleToProbe,

  /// The module was asked and said no.
  moduleAnsweredNo,

  /// The module was asked and said yes.
  moduleAnsweredYes,
}

/// Resolves the status from a probe outcome, and from nothing else.
///
/// THE RULE THAT OUTLIVES TODAY'S STATE: an available result may only ever come
/// from a probe that observed the module working at run time, on the device that
/// is running. Never from a compile-time constant, never from
/// `bool.fromEnvironment`, never from a platform or version check. A build flag
/// can only ever describe what someone intended to link; the question here is
/// what actually answers.
///
/// Today every branch returns absent, and that is structural rather than
/// policy: there is no expression in this library that could produce an
/// available value, because no such type exists to produce.
NativeShapeAvailability resolveNativeShapeAvailability(
  NativeShapeProbeOutcome outcome,
) => switch (outcome) {
  NativeShapeProbeOutcome.noModuleToProbe => const NativeShapeAbsent(
    NativeShapeAbsentCause.noModuleLinked,
  ),
  NativeShapeProbeOutcome.moduleAnsweredNo => const NativeShapeAbsent(
    NativeShapeAbsentCause.moduleReportedUnavailable,
  ),
  NativeShapeProbeOutcome.moduleAnsweredYes => const NativeShapeAbsent(
    NativeShapeAbsentCause.probeSucceededButPresentStateNotRepresentable,
  ),
};

/// The status for a build with no native module linked, which is every build
/// this repository produces today.
///
/// A named constant rather than a literal at each call site: one place to change
/// on the day the probe becomes real, and one place for a reader to look.
const NativeShapeAvailability nativeShapeAvailabilityForThisBuild =
    NativeShapeAbsent(NativeShapeAbsentCause.noModuleLinked);
