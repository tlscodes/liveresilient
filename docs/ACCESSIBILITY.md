# Accessibility — VoiceCallKit v2

Target: WCAG 2.2 AA equivalence for the mobile app, using the platform
accessibility stacks (TalkBack, VoiceOver, Switch Access) via Flutter's
semantics layer. Communication apps are lifelines; an inaccessible calling
app excludes exactly the people who may depend on it most.

## Requirements by area

### Calling UX
- Every call control (answer, decline, hang up, mute, camera, speaker) has
  a semantic label, a minimum 48×48dp touch target, and is reachable by
  screen reader in a logical focus order.
- Incoming calls announce caller and call type through the screen reader
  and support answering via assistive tech, not only swipe gestures.
- All call states (`connecting`, `reconnecting`, `audio-only fallback`,
  `ended`) are announced as live-region updates — a blind user must know
  the call degraded to audio-only without looking.
- Haptic patterns accompany ring, connect, and disconnect events.

### Degraded-mode transparency
- Quality changes from `AdaptiveMediaPolicy` surface as concise,
  non-technical announcements ("Video paused to protect audio"), rated at
  most one announcement per profile change (no announcement storms during
  flapping — the policy's hysteresis also protects assistive users).
- Connection-state UI never relies on color alone; icons and text labels
  carry the same information (color-vision safe).

### Deaf and hard-of-hearing users
- Video quality floor: the policy's `minimal` tier keeps frame rate ≥ 10fps
  where bandwidth allows, because sign language and lip reading need
  motion, not resolution. When only audio survives, the UI states that
  clearly so a Deaf user is not left on a silent call.
- Full support for platform captioning hooks where the OS provides them.

### Motor and cognitive accessibility
- No time-critical gestures: every swipe action has a button alternative.
- Reconnect flows are fully automatic (`ReconnectPolicy`); users are never
  required to perform rapid manual steps to save a call.
- Plain-language safety prompts: key-change warnings and consent dialogs
  (nearby connectivity, telemetry) are written at a general reading level,
  translated, and never use jargon like "TOFU" or "fingerprint" without
  explanation.

### Visual
- Text scales to 200% without loss of function.
- Contrast ratio ≥ 4.5:1 for text, ≥ 3:1 for essential icons, verified in
  both light and dark themes.
- Reduced-motion setting disables decorative animation.

## Engineering process

- Semantics coverage is part of widget-test acceptance for every screen
  (`apps/reference_app/test`).
- Screen-reader smoke pass (TalkBack + VoiceOver) is a release checklist
  item on the riskiest flows: receive call, in-call controls, key-change
  warning, consent dialogs.
- Accessibility defects triage at the same severity scale as functional
  defects; a screen-reader-unreachable answer button is a release blocker.
