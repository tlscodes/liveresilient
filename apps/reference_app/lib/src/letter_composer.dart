// The letter: what a person can leave in a Send window and how it is
// authored. Shared by the reference app's own letter sheet and the rig
// peer (which extends [LetterComposer]).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'photo_letter_picker.dart';
import 'voice_letter_recorder.dart';

/// What the screen shows for a carried payload: the text when it IS text,
/// a description when it is not. Strict decoding on purpose — a lenient
/// decode would print a binary payload as garbage and a person would read
/// that as a corrupted letter.
String describeLetter(Uint8List payload, String sha256) {
  try {
    return utf8.decode(payload);
  } on FormatException {
    return '<binary, ${payload.length} B, sha256 ${sha256.substring(0, 16)}>';
  }
}

/// Where the letter is, as the person holding the phone must read it.
///
/// One value, one banner, so the screen never sits on a heartbeat with no
/// verdict: the live call is unavailable and the door is the way; the
/// letter is queued at the door; the letter arrived; or it did not, and
/// why. The door line keeps ticking underneath — this is the verdict.
enum LetterState {
  /// The WAN probe failed: no live call from here, the letter goes through
  /// the door.
  liveCallUnavailable,

  /// Handed over (typed, recorded or picked), waiting at the door.
  queued,

  /// The door answered every chunk: the letter is on the Mac.
  arrived,

  /// The carry ended without arrival — refused, parked, timed out or
  /// failed. Never a spinner: the detail names the reason.
  notDelivered,
}

/// What the letter banner says for each state, before its detail.
String letterStateLabel(LetterState state) {
  switch (state) {
    case LetterState.liveCallUnavailable:
      return 'Live call unavailable — this letter goes through the door';
    case LetterState.queued:
      return 'Letter queued at the door';
    case LetterState.arrived:
      return 'Letter arrived';
    case LetterState.notDelivered:
      return 'Letter not delivered';
  }
}

/// The banner's whole truth: a state and one line of detail under it.
class LetterStatus {
  const LetterStatus(this.state, [this.detail = '']);

  final LetterState state;
  final String detail;

  @override
  String toString() => detail.isEmpty
      ? letterStateLabel(state)
      : '${letterStateLabel(state)} · $detail';
}

/// The Record button's whole truth. One value, rendered by one button, so
/// idle and recording can never look alike.
enum VoiceRecordState {
  /// Nothing captured yet, or the last take was refused.
  idle,

  /// The microphone is opening (a platform round-trip, and on a fresh
  /// install a permission prompt) — taps are joined, not dropped.
  starting,

  /// Capturing. The button shows the elapsed counter against the cap.
  recording,

  /// Stopped; encoding to Codec2 700C.
  stopping,

  /// A letter is in hand, waiting for Send.
  recorded,
}

/// Something the person holding the phone must see and dismiss by hand.
class VoiceAlert {
  const VoiceAlert(this.message, {this.isError = true});

  final String message;

  /// False for the cap notice, which reports a success.
  final bool isError;
}

/// The plain-words reason a recording produced no letter. Each refusal says
/// what to do differently; the old single line ("too short or off-rate")
/// could not tell a half-second tap from a plugin delivering the wrong
/// sample rate.
String voiceRefusalText(VoiceRecording recorder) {
  switch (recorder.refusal) {
    case VoiceLetterRefusal.tooShort:
      return 'Too short — only ${recorder.elapsed.inMilliseconds} ms was '
          'captured. Tap Record, speak for at least a few seconds, then tap '
          'Stop.';
    case VoiceLetterRefusal.offRate:
      return 'The microphone delivered ${recorder.pcmBytes} bytes for '
          '${recorder.elapsed.inSeconds}s, not the '
          '${recorder.elapsed.inMilliseconds * 16} expected. The recording '
          'was refused rather than carried as noise.';
    case VoiceLetterRefusal.failed:
      return 'The recording failed: ${recorder.stopError}';
    case VoiceLetterRefusal.notStarted:
    case null:
      return 'The recording never started — nothing was captured.';
  }
}

/// `m:ss`, for the counter on a recording button.
String voiceClock(Duration value) {
  final seconds = value.inSeconds < 0 ? 0 : value.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// What the Record button says in each state. A first-time user reads only
/// this, so every state names itself and the live one carries its counter.
String voiceRecordButtonLabel(VoiceRecordState state, Duration elapsed) {
  switch (state) {
    case VoiceRecordState.idle:
      return 'Record voice (30 s cap)';
    case VoiceRecordState.starting:
      return 'Opening microphone…';
    case VoiceRecordState.recording:
      return 'STOP • ${voiceClock(elapsed)} / '
          '${voiceClock(voiceLetterMaxLength)}';
    case VoiceRecordState.stopping:
      return 'Encoding…';
    case VoiceRecordState.recorded:
      return 'Recorded ${voiceClock(elapsed)} — tap to redo';
  }
}

/// The Photo button's whole truth, in the shape [VoiceRecordState] already
/// proved out: one value, rendered by one button, so "nothing chosen" and
/// "still shrinking a 4 MB screenshot" can never look alike.
enum PhotoPickState {
  /// Nothing chosen yet, or the last pick was refused.
  idle,

  /// The system photo picker is open, or opening.
  picking,

  /// A photo is in hand and the size ladder is running on a worker isolate.
  shrinking,

  /// A letter-sized photo is in hand, waiting for Send.
  picked,
}

/// The plain-words reason a pick produced no letter. Each refusal says what
/// to do differently, the same way [voiceRefusalText] does — "it didn't
/// work" is not something a person standing in a 120 s window can act on.
String photoRefusalText(PhotoLetterRefusal? refusal, {String? error}) {
  switch (refusal) {
    case PhotoLetterRefusal.cancelled:
      return 'No photo was chosen — the picker closed without one. Tap Photo '
          'again and choose a picture, for example a screenshot.';
    case PhotoLetterRefusal.unreadable:
      return 'That file could not be read as a picture. Choose a photo or a '
          'screenshot from the library, not a document.';
    case PhotoLetterRefusal.tooLarge:
      return 'That picture could not be made to fit '
          '${photoLetterSize(photoLetterMaxBytes)} — even at '
          '${photoLetterEdges.last} px it stayed larger. Choose a simpler '
          'picture.';
    case PhotoLetterRefusal.failed:
      return 'Preparing the photo failed: ${error ?? 'no reason reported'}';
    case null:
      return 'The photo was never prepared — nothing was chosen.';
  }
}

/// What the Photo button says in each state. A first-time user reads only
/// this, so every state names itself and the finished one carries the two
/// numbers that decide whether it can ride the lane: bytes and pixels.
String photoPickButtonLabel(PhotoPickState state, PhotoLetter? letter) {
  switch (state) {
    case PhotoPickState.idle:
      return 'Thumbnail (≤${photoLetterSize(photoLetterMaxBytes)})';
    case PhotoPickState.picking:
      return 'Choosing a photo…';
    case PhotoPickState.shrinking:
      return 'Shrinking to fit…';
    case PhotoPickState.picked:
      if (letter == null) return 'Thumbnail ready — tap to redo';
      return 'Thumbnail ${photoLetterSize(letter.wire.length)} · '
          '${letter.width}×${letter.height} — tap to redo';
  }
}

/// Which of the things a person can leave in a Send window becomes the
/// letter, and what the row calls it.
///
/// Pure on purpose: the ranking is the part most likely to be got wrong and
/// the part hardest to reach through a live job, so it is decided here and
/// tested here. A recording first — when both it and a photo are in hand the
/// recording is always the newer act, because picking a photo clears a
/// recording that was waiting and never the other way round. Then the photo,
/// then the typed draft, then the run's own default letter.
(String, Uint8List) phoneLetterChoice({
  required VoiceLetter? voice,
  required PhotoLetter? photo,
  required String draft,
  required String fallback,
}) {
  if (voice != null) return ('voice', voice.wire);
  if (photo != null) return ('photo', photo.wire);
  final typed = draft.trim();
  if (typed.isEmpty) {
    return ('default', Uint8List.fromList(utf8.encode(fallback)));
  }
  return ('typed', Uint8List.fromList(utf8.encode(typed)));
}

/// The authoring half of a letter: the typed draft, one voice take, one
/// thumbnail, and the two alerts. Every state is a notifier the buttons
/// render verbatim, so the screen has exactly one answer to "is it
/// recording?" and "is it still shrinking?".
///
/// [note] receives one raw line per act (started, recorded, chosen,
/// failed); the rig peer prints it as `JOURNEY_PEER …`, the app keeps it
/// on screen.
class LetterComposer {
  /// One raw line per act. Overridden by hosts that log; no-op here.
  void note(String line) {}

  /// What the person typed on the phone screen; carried verbatim when the
  /// job says `chat_source: phone`. Never cleared by a job, so a draft typed
  /// before the run is the one that goes.
  final ValueNotifier<String> draft = ValueNotifier<String>('');

  /// A voice letter recorded during the current Send window, if any.
  /// Takes priority over `draft` when non-null; cleared once the letter
  /// is built so a stale recording never rides the next job.
  final ValueNotifier<VoiceLetter?> voiceLetter = ValueNotifier<VoiceLetter?>(
    null,
  );

  /// What the Record button is doing right now. The button renders this and
  /// nothing else, so there is exactly one answer on screen to "is it
  /// recording?" — the old button read `voiceLetter`, which is null both
  /// before a recording and during one, so idle and recording looked
  /// identical to the person holding the phone.
  final ValueNotifier<VoiceRecordState> recordState =
      ValueNotifier<VoiceRecordState>(VoiceRecordState.idle);

  /// How long the live recording has run. Ticks while
  /// [VoiceRecordState.recording], frozen at the final length afterwards.
  final ValueNotifier<Duration> recordElapsed = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// A message the person must see and dismiss by hand: a recording that
  /// failed or was refused, or the 30 s cap closing one on its own. The
  /// event list below is a 40-line scrolling log of lane counters — a
  /// failure written only there is, in practice, invisible mid-task, which
  /// is exactly how a 120 s window was spent with nothing captured and
  /// nothing on screen to say so.
  final ValueNotifier<VoiceAlert?> voiceAlert = ValueNotifier<VoiceAlert?>(
    null,
  );

  /// Clears the banner. Only a tap does this — no timeout, no next event.
  void dismissVoiceAlert() => voiceAlert.value = null;

  /// Builds the recording this peer drives. Overridden in tests, which have
  /// no microphone; production is always [VoiceLetterRecorder].
  @visibleForTesting
  VoiceRecording Function() newRecording = VoiceLetterRecorder.new;

  VoiceRecording? _recorder;
  Future<void>? _transition;
  Timer? _recordTicker;

  /// Starts recording on the first tap, stops and encodes on the second.
  /// Any failure (permission denied, rate guard, codec error) is caught
  /// here and only disables voice for this window — the typed-text path
  /// is never touched by a voice failure.
  ///
  /// A tap that lands while a start or a stop is still in flight JOINS that
  /// transition instead of beginning another one. It used to begin another
  /// one: `_recorder` was assigned only after `start()` resolved, so a
  /// second tap during the platform's microphone-open round-trip opened a
  /// second [AudioRecorder] and orphaned the first with the microphone
  /// held.
  Future<void> toggleRecording() {
    final live = _transition;
    if (live != null) return live;
    final work = _transition = _toggle().whenComplete(() => _transition = null);
    return work;
  }

  Future<void> _toggle() async {
    final live = _recorder;
    if (live == null) return _startRecording();
    return _finishRecording(live);
  }

  Future<void> _startRecording() async {
    recordState.value = VoiceRecordState.starting;
    voiceAlert.value = null;
    voiceLetter.value = null;
    recordElapsed.value = Duration.zero;
    final recorder = newRecording();
    recorder.onCapReached = (letter, refusal) => _capReached(recorder, letter);
    try {
      await recorder.start();
    } on Object catch (error) {
      recordState.value = VoiceRecordState.idle;
      _voiceFailed('The microphone did not open. $error');
      return;
    }
    _recorder = recorder;
    recordState.value = VoiceRecordState.recording;
    _recordTicker = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => recordElapsed.value = recorder.elapsed,
    );
    note('voice recording started, cap ${voiceLetterMaxLength.inSeconds}s');
  }

  Future<void> _finishRecording(VoiceRecording live) async {
    recordState.value = VoiceRecordState.stopping;
    _recorder = null;
    _stopTicker();
    _settle(live, await live.stop(), capped: false);
  }

  void _capReached(VoiceRecording recorder, VoiceLetter? letter) {
    // A tap already finished this one; its own `stop()` returns the same
    // letter, so there is nothing left to settle here.
    if (!identical(_recorder, recorder)) return;
    _recorder = null;
    _stopTicker();
    _settle(recorder, letter, capped: true);
  }

  void _stopTicker() {
    _recordTicker?.cancel();
    _recordTicker = null;
  }

  void _settle(
    VoiceRecording recorder,
    VoiceLetter? letter, {
    required bool capped,
  }) {
    recordElapsed.value = recorder.elapsed;
    voiceLetter.value = letter;
    if (letter == null) {
      recordState.value = VoiceRecordState.idle;
      _voiceFailed(voiceRefusalText(recorder));
      return;
    }
    recordState.value = VoiceRecordState.recorded;
    note(
      'voice recorded ${letter.length.inSeconds}s '
      '${letter.wire.length}B frames=${letter.frames} capped=$capped',
    );
    if (capped) {
      voiceAlert.value = VoiceAlert(
        'Maximum ${voiceLetterMaxLength.inSeconds}s reached. The recording '
        'is saved (${letter.length.inSeconds}s) — tap Send letter to carry '
        'it.',
        isError: false,
      );
    }
  }

  void _voiceFailed(String message) {
    voiceAlert.value = VoiceAlert(message);
    note('voice failed: $message');
  }

  /// Finalizes a recording that is still running and waits out one already
  /// being encoded, without ever starting a new one. The Send window calls
  /// this before it reads [voiceLetter]: a Stop tap at the very end of the
  /// window would otherwise still be encoding when the letter is read, and
  /// the take would be dropped for a default letter.
  Future<void> finalizeRecording() async {
    final live = _transition;
    if (live != null) await live;
    if (_recorder != null) await toggleRecording();
  }

  /// A photo chosen and shrunk during the current Send window, if any.
  /// Cleared once the letter is built, so a stale picture never rides the
  /// next job — the same contract [voiceLetter] has.
  ///
  /// Voice outranks it in the Send window, and that ranking is what
  /// makes "the last thing you did is the letter" true in both orders: a
  /// pick clears a recording that was waiting (see [pickPhoto]), and a recording
  /// started after a pick wins by rank. Nobody has to remember which button
  /// they touched first.
  final ValueNotifier<PhotoLetter?> photoLetter = ValueNotifier<PhotoLetter?>(
    null,
  );

  /// What the Photo button is doing right now. The button renders this and
  /// nothing else, so there is exactly one answer on screen to "is it still
  /// working on my picture?".
  final ValueNotifier<PhotoPickState> photoState =
      ValueNotifier<PhotoPickState>(PhotoPickState.idle);

  /// The photo half of [voiceAlert] — a pick that failed or was refused,
  /// shown big, next to the button, until the person dismisses it by hand.
  /// Its own notifier and not a shared one: a photo failure must not
  /// silently overwrite a recording failure nobody has read yet.
  final ValueNotifier<VoiceAlert?> photoAlert = ValueNotifier<VoiceAlert?>(
    null,
  );

  /// Clears the photo banner. Only a tap does this.
  void dismissPhotoAlert() => photoAlert.value = null;

  /// Builds the pick this peer drives. Overridden in tests, which have no
  /// photo library; production is always [GalleryPhotoSelection].
  @visibleForTesting
  PhotoSelection Function() newPhotoSelection = GalleryPhotoSelection.new;

  Future<void>? _pickTransition;

  /// Opens the photo picker, shrinks what comes back until it fits the
  /// lane's cap, and holds it for Send.
  ///
  /// A tap that lands while a pick is still in flight JOINS it rather than
  /// opening a second picker — the rule [toggleRecording] learned the hard
  /// way with two live microphones.
  Future<void> pickPhoto() {
    final live = _pickTransition;
    if (live != null) return live;
    final work = _pickTransition = _pick().whenComplete(
      () => _pickTransition = null,
    );
    return work;
  }

  Future<void> _pick() async {
    photoState.value = PhotoPickState.picking;
    photoAlert.value = null;
    photoLetter.value = null;
    // One letter, one payload. A photo replaces a recording that was waiting
    // for Send, and the Record button visibly drops back to idle — nothing
    // is discarded behind the person's back.
    if (voiceLetter.value != null) {
      voiceLetter.value = null;
      recordState.value = VoiceRecordState.idle;
      recordElapsed.value = Duration.zero;
      note('photo replaces the recording that was waiting for Send');
    }
    final selection = newPhotoSelection();
    final Uint8List? source;
    try {
      source = await selection.pick();
    } on Object catch (error) {
      photoState.value = PhotoPickState.idle;
      _photoFailed('The photo library did not open. $error');
      return;
    }
    if (source == null) {
      photoState.value = PhotoPickState.idle;
      _photoFailed(photoRefusalText(PhotoLetterRefusal.cancelled));
      return;
    }
    photoState.value = PhotoPickState.shrinking;
    final result = await selection.shrink(source);
    final letter = result.letter;
    if (letter == null) {
      photoState.value = PhotoPickState.idle;
      _photoFailed(
        photoRefusalText(result.refusal, error: selection.pickError),
      );
      return;
    }
    photoLetter.value = letter;
    photoState.value = PhotoPickState.picked;
    note(
      'photo chosen ${letter.wire.length}B '
      '${letter.width}x${letter.height} q${letter.quality} '
      'from ${letter.sourceBytes}B',
    );
  }

  void _photoFailed(String message) {
    photoAlert.value = VoiceAlert(message);
    note('photo failed: $message');
  }

  /// Waits out a pick already in flight, without ever starting one. The Send
  /// window calls this before it reads [photoLetter] for the same reason it
  /// calls [finalizeRecording]: a tap at the very end of the window would
  /// otherwise still be shrinking when the letter is read, and the picture
  /// would be dropped for a default letter.
  Future<void> finalizePick() async {
    final live = _pickTransition;
    if (live != null) await live;
  }

  /// Stops a live recording and releases the ticker. Safe to call twice.
  Future<void> disposeComposer() async {
    _stopTicker();
    final live = _recorder;
    _recorder = null;
    if (live != null) {
      try {
        await live.stop();
      } on Object {
        // Releasing on the way out; nothing left to report to.
      }
    }
  }
}
