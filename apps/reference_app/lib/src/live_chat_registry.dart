/// Where the live call's chat thread is published for observers outside the
/// widget tree.
///
/// The app binds a [ChatDemoController] to the call's data lanes the moment
/// a session exists and unbinds it when the session goes ([HomePage] owns
/// that lifecycle). The app-journey driver measures a send through the real
/// screens, then reads what the controller recorded — delivery ticks and the
/// sender-side sha256 of every photo, note and file — instead of scraping
/// pixels. Null whenever no call is live.
library;

import 'package:flutter/foundation.dart';

import 'chat_demo_controller.dart';

final ValueNotifier<ChatDemoController?> liveChatController =
    ValueNotifier<ChatDemoController?>(null);
