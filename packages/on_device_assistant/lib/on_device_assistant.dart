/// On-device assistant port: user-facing language intelligence behind one
/// swappable interface.
///
/// Division of labor is deliberate: the connectivity brain (statistical,
/// deterministic, millisecond-fast) OWNS routing decisions; the assistant
/// only turns system state into human language — explanations, summaries,
/// drafts. An LLM engine (Gemma via flutter_gemma, llama.cpp over FFI)
/// plugs in behind [OnDeviceAssistant]; the rule-based default ships
/// today, works with zero model download, and keeps every test
/// deterministic.
library;

export 'src/assistant_port.dart';
export 'src/rule_based_assistant.dart';
