/// Message-status badge: the animated tick ladder driven ONLY by real
/// network signals (see `network_truth.dart` for the sourcing contract).
///
/// Visual language:
///   sending   → small progress ring (in-flight, unproven)
///   sent      → one tick, pending color (frame written)
///   delivered → two ticks, pending color (real ack)
///   verified  → shield-check, verified color (sha proven)
///   failed    → error mark, danger color, tappable to retry
///
/// State changes cross-fade over [AppMotion.fast]; nothing repeats, so the
/// badge is `pumpAndSettle`-safe by construction.
library;

import 'package:flutter/material.dart';

import 'network_truth.dart';
import 'tokens.dart';

class MessageStatusBadge extends StatelessWidget {
  const MessageStatusBadge({
    super.key,
    required this.status,
    this.onRetry,
    this.color,
  });

  final MessageTruthStatus status;

  /// Offered only for [MessageTruthStatus.failed]; taps elsewhere are inert.
  final VoidCallback? onRetry;

  /// Overrides the ladder's neutral color (bubbles pass their foreground so
  /// ticks stay readable on the primary fill).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final neutral = color ?? tokens.pending;
    final (child, semantics) = switch (status) {
      MessageTruthStatus.sending => (
        SizedBox(
          key: const ValueKey('status-sending'),
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 1.6, color: neutral),
        ),
        'Sending',
      ),
      MessageTruthStatus.sent => (
        Icon(
          Icons.check,
          key: const ValueKey('status-sent'),
          size: 15,
          color: neutral,
        ),
        'Sent',
      ),
      MessageTruthStatus.delivered => (
        Icon(
          Icons.done_all,
          key: const ValueKey('status-delivered'),
          size: 15,
          color: neutral,
        ),
        'Delivered',
      ),
      MessageTruthStatus.verified => (
        Icon(
          Icons.verified_user,
          key: const ValueKey('status-verified'),
          size: 15,
          color: color ?? tokens.verified,
        ),
        'Verified end-to-end',
      ),
      MessageTruthStatus.failed => (
        Icon(
          Icons.error_outline,
          key: const ValueKey('status-failed'),
          size: 15,
          color: tokens.danger,
        ),
        'Failed — tap to retry',
      ),
    };
    final badge = Semantics(
      label: semantics,
      child: AnimatedSwitcher(
        duration: AppMotion.fast,
        switchInCurve: AppMotion.standard,
        switchOutCurve: AppMotion.standard,
        child: child,
      ),
    );
    if (status == MessageTruthStatus.failed && onRetry != null) {
      return GestureDetector(
        onTap: () {
          AppHaptics.warning();
          onRetry!();
        },
        behavior: HitTestBehavior.opaque,
        child: badge,
      );
    }
    return badge;
  }
}
