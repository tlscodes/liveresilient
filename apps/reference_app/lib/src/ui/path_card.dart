import 'package:connection_orchestrator/connection_orchestrator.dart';
import 'package:flutter/material.dart';

import 'quality_gauge.dart' show tokensOrDefault;
import 'tokens.dart';

/// The lane the connectivity fabric will send on next, named for the person
/// on the call, with the fabric's mode beside it.
///
/// [ConnectivitySnapshot.bestLaneId] is the ranked-first eligible lane — the
/// path the next message takes — not a receipt for the last one, which is
/// why the card says "path" and never "delivered via". Until now nothing on
/// the screen said which of the six lanes was carrying the call: survival
/// mode read the same whether the relay, the DNS valve or the local mesh
/// was doing the work.
class PathCard extends StatelessWidget {
  const PathCard({super.key, required this.connectivity});

  final Stream<ConnectivitySnapshot> connectivity;

  @override
  Widget build(BuildContext context) {
    final tokens = tokensOrDefault(context);
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsetsDirectional.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.r16),
        side: BorderSide(color: tokens.outlineSoft),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.all(AppSpacing.s16),
        child: StreamBuilder<ConnectivitySnapshot>(
          stream: connectivity,
          builder: (context, snapshot) {
            final current = snapshot.data;
            return Row(
              children: [
                Icon(Icons.alt_route, size: 18, color: colors.onSurfaceVariant),
                const SizedBox(width: AppSpacing.s8),
                Expanded(
                  child: Text(
                    current == null
                        ? 'Path: not reported yet'
                        : 'Path: ${pathLabel(current)}',
                    key: const Key('path-card-label'),
                    style: text.bodyMedium,
                  ),
                ),
                if (current != null)
                  Text(
                    fabricModeLabel(current.mode),
                    key: const Key('path-card-mode'),
                    style: text.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The fabric's lane ids, as the person on the call would name them. Ids the
/// fabric grows later fall through unchanged rather than being hidden.
String laneLabel(String id) => switch (id) {
  'webrtc-media' => 'direct media',
  'resilient.udp' => 'direct UDP fallback',
  'resilient.wss' => 'relay (WebSocket)',
  'resilient.https' => 'relay (HTTPS long-poll)',
  'resilient.dns-valve' => 'DNS valve',
  'resilient.mesh' => 'local mesh',
  _ => id,
};

String fabricModeLabel(FabricMode mode) => switch (mode) {
  FabricMode.live => 'live',
  FabricMode.degraded => 'degraded',
  FabricMode.storeAndForward => 'store-and-forward',
  FabricMode.offline => 'offline',
};

/// One line for the snapshot: the best lane's name, or what is happening to
/// messages while there is none.
String pathLabel(ConnectivitySnapshot snapshot) {
  final id = snapshot.bestLaneId;
  if (id == null) {
    return snapshot.pendingBundles > 0
        ? 'none — ${snapshot.pendingBundles} message(s) stored'
        : 'none';
  }
  return laneLabel(id);
}
