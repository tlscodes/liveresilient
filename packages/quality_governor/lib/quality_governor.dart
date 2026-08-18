/// Closes the control loop that `network_quality_policy` opens.
///
/// That package classifies the link and produces a rung of knobs, and its own
/// comment (network_quality_policy.dart:138-141) records that nothing reads
/// them back — they are data with no consumer. This package is the consumer,
/// under one invariant: voice is never cut.
library;

export 'src/quality_governor.dart'
    show GovernorConfig, LinkObservation, QualityDecision, QualityGovernor;
export 'src/quality_rung.dart'
    show QualityRung, qualityLadder, survivalRungIndex;
