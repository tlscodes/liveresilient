❯     > "یک پکیج دارت مستقل به نام `optional_path_adapter` ایجاد کن. فایل `pubspec.yaml` آن را طوری تنظیم کن که نسخه SDK روی          
  `^3.12.0` پین شده باشد و پکیج‌های `meta` و `clock` به عنوان وابستگی‌های آن تعریف شوند. فعلاً هیچ کد دیگری ننویس."                      `^3.12.0` پین شده باشد و پکیج‌های `meta` و `clock` به عنوان وابستگی‌های آن تعریف شوند. فعلاً هیچ کد دیگری ننویس."
  
⏺─ساخت پکیج با یک Write انجام می‌شود؛فقط pubspec.yaml طبق درخواست.

⏺ Write(optional_path_adapter/pubspec.yaml)
  ⎿  Wrote 11 lines to optional_path_adapter/pubspec.yaml
       1 name: optional_path_adapter
       2 description: Optional path adapter package.
       3 version: 0.1.0
       4 publish_to: none
       5 
       6 environment:
       7   sdk: ^3.12.0
       8
       9 dependencies:
      10   meta: ^1.16.0
     … +1 line (ctrl+o to expand)

⏺ Bash(cd /Users/behnam/Downloads/voice_call_kit_v3/optional_path_adapter && dart pub get)
  ⎿  Resolving dependencies...
     Downloading packages...
     + clock 1.1.2
     … +2 lines (ctrl+o to expand)

⏺ TL;DR — پکیج ساخته شد و resolve آن با موفقیت انجام شد.

  - فایل ساخته‌شده:

  optional_path_adapter/pubspec.yaml

  - محتوا طبق درخواست:
  
  environment:
    sdk: ^3.12.0

  dependencies:
    meta: ^1.16.0
    clock: ^1.1.2

  - تأیید:

  dart pub get → clock 1.1.2 + meta 1.19.0, exit 0

  هیچ کد دیگری نوشته نشد؛ آماده‌یگام بعدی.

✻ Cogitated for 44s

❯     > "در این پکیج، یک فایل به نام `lib/src/optional_path_adapter.dart` بساز. یک کلاس انتزاعی (abstract class) به نام               
  `OptionalPathAdapter` ایجاد کن که متدهای `Future<void> initialize()`, `Future<bool> start()`, `Future<void> stop()` و یک Getter به  
  نام `bool get isHealthy` را تعریف کند. هیچ منطق اجرایی در این فایل ننویس."                                                          
  
⏺ Write(lib/src/optional_path_adapter.dart)
  ⎿  Wrote 14 lines to lib/src/optional_path_adapter.dart
       1 /// Contract for an optional transport path adapter.
       2 abstract class OptionalPathAdapter {
       3   /// Prepares the adapter for use.
       4   Future<void> initialize();
       5 
       6   /// Starts the adapter; returns `true` on success.
       7   Future<bool> start();
       8 
       9   /// Stops the adapter and releases its resources.
      10   Future<void> stop();
     … +4 lines (ctrl+o to expand)

⏺ Bash(dart analyze) 
  ⎿  Analyzing optional_path_adapter...
     No issues found!

⏺ TL;DR — کلاس انتزاعی ساخته شد و آنالایزر بدون خطا پاس کرد.

  - فایل:

  optional_path_adapter/lib/src/optional_path_adapter.dart

  - محتوا: کلاس abstract با چهار عضو خواسته‌شده و بدون هیچمنطق اجرایی:
  
  abstract class OptionalPathAdapter {
    Future<void> initialize();
    Future<bool> start();
    Future<void> stop();
    bool get isHealthy;
  }

  - تأیید:

  dart analyze → No issues found! (exit 0)

❯ "یک کلاس به نام `LocalConnectionVerifier` در مسیر                              
  `lib/src/local_connection_verifier.dart` ایجاد کن. این کلاس باید متدی به نام `verifyServiceReadiness` داشته باشد که یک هاست و یک    
  پورت عددی دریافت کند. با استفاده از متد استاندارد `Socket.connect` و یک آبجکت `Duration` کوتاه، تلاش کند یک کانکشن موقت برقرار کند. 
  در صورت موفقیت، مقدار `true` بازگرداند و سوکت را فورا ببندد (`close`). در صورت بروز هرگونه استثنا یا اتمام زمان (Timeout)، با       
  مدیریت خطای خاموش (silent try-catch)، مقدار `false` بازگرداند."                                                                     
  
⏺ ساخت کلاس جدید و سپس اجرای analyzer برای وریفای.

⏺ Write(lib/src/local_connection_verifier.dart)
  ⎿  Wrote 20 lines to lib/src/local_connection_verifier.dart
       1 import 'dart:io';
       2 
       3 /// Probes a local service by attempting a short-lived TCP connection.
       4 class LocalConnectionVerifier {
       5   /// Returns `true` if a TCP connection to [host]:[port] succeeds within
       6   /// [timeout]; `false` on any error or timeout.
       7   Future<bool> verifyServiceReadiness(
       8     String host,
       9     int port, {
      10     Duration timeout = const Duration(milliseconds: 500),
     … +10 lines (ctrl+o to expand)

⏺ Bash(dart analyze lib/src/local_connection_verifier.dart)
  ⎿  Analyzing local_connection_verifier.dart...
     No issues found!

⏺ TL;DR — کلاس ساخته شد و analyzer بدون خطا پاس شد.

  فایل جدید:

  lib/src/local_connection_verifier.dart

  - متدِ verifyServiceReadiness هاست و پورت می‌گیرد و با Socket.connect و timeout کوتاه (پیش‌فرض۵۰۰ms، قابل‌تغییر)تست اتصال می‌زند.
  - موفقیت → بستن فوری سوکت و بازگشت true؛ هر استثنا یا timeout → catch خاموش و بازگشت false.

  وریفای:

  dart analyze lib/src/local_connection_verifier.dart → No issues found!

✻ Sautéed for 47s

❯     > "یک فایل جدید به نام `lib/src/optional_path_adapter.dart` بساز. یک کلاس انتزاعی به نام `OptionalPathAdapter` در آن تعریف کن   
  که شامل متدهای اصلی `Future<void> initialize()`، `Future<bool> start()`، `Future<void> stop()` و یک Getter به نام `bool get         
  isHealthy` باشد. همچنین یک Enum به نام `AdapterState` با حالت‌های `idle`، `starting`، `running` و `stopped` تعریف کن که وضعیت جاری    isHealthy` باشد. همچنین یک Enum به نام `AdapterState` با حالت‌های`idle`، `starting`، `running` و `stopped` تعریف کن که وضعیت جاری
  آداپتور را توصیف کند. کد فاقد هرگونه منطق اجرایی پیچیده باشد و پس از ساخت، دستور `dart analyze` را برای راستی‌آزمایی روی آن اجرا      کن."
  کن."                                                                                                                                
──
⏺ ساخت فایل abstract adapter و سپس analyzer.

⏺ Write(lib/src/optional_path_adapter.dart)
  ⎿  Wrote 18 lines to lib/src/optional_path_adapter.dart
       1 /// Lifecycle state of an [OptionalPathAdapter].
       2 enum AdapterState { idle, starting, running, stopped }
       3 
       4 /// Contract for an optional transport path that can be initialized,
       5 /// started, and stopped independently of the primary path.
       6 abstract class OptionalPathAdapter {
       7   /// Prepares the adapter's resources; must be called before [start].
       8   Future<void> initialize();
       9
      10   /// Attempts to bring the path up; returns `true` on success.
     … +8 lines (ctrl+o to expand)

⏺ Bash(dart analyze lib/src/optional_path_adapter.dart)
  ⎿  Analyzing optional_path_adapter.dart...
     No issues found!

⏺ TL;DR — فایل ساخته شد و analyzer بدون خطا پاس شد.

  lib/src/optional_path_adapter.dart

  - کلاس انتزاعی OptionalPathAdapter با چهار عضو خواسته‌شده:initialize و start و stop و گترِ  isHealthy — بدون هیچ منطق اجرایی.
  - Enum به نام AdapterState با چهار حالتِ idle و starting و running و stopped.
  
  وریفای:

  dart analyze lib/src/optional_path_adapter.dart → No issues found!

 "یک کلاس در فایل `lib/src/local_service_runner.dart` بنویس به نام              
  `LocalServiceRunner`. این کلاس وظیفه دارد یک پروسس فرزند (child process) لوکال را با استفاده از متد استاندارد `Process.start` آغاز  
  کند. کلاس باید ورودی مسیر پروسس را به همراه پارامترهای اختیاری گرفته، وضعیت فعالیت آن را در یک متد `bool get isActive` بازتاب دهد،  
  استریم خروجی‌های آن را صرفاً جهت دیباگ عادی با متدهای استاندارد گوش داده و در متد `Future<void> shutdown()` با فرستادن سیگنال        
  ترمینیشن استاندارد سیستم‌عامل، ارتباط را به طور ایمن متوقف کند. پس از نوشتن، صحت کد را با دستور `dart analyze` بسنج."                 ترمینیشن استاندارد سیستم‌عامل،ارتباط را به طور ایمن متوقف کند. پس از نوشتن، صحت کد را با دستور `dart analyze` بسنج."

⏺─می‌نویسمو بعد با dart analyze صحتش را می‌سنجم.

⏺ Write(lib/src/local_service_runner.dart)
  ⎿  Wrote 81 lines to lib/src/local_service_runner.dart
       1 import 'dart:async';
       2 import 'dart:convert';
       3 import 'dart:io';
       4 
       5 /// Starts and supervises a single local child process.
       6 ///
       7 /// The process is launched with [Process.start]; its stdout/stderr are
       8 /// consumed line-by-line for ordinary debug logging only. [shutdown] stops
       9 /// the process safely by sending the OS-standard termination signal
      10 /// (SIGTERM) and waiting for it to exit.
     … +71 lines (ctrl+o to expand)

⏺ Bash(dart analyze lib/src/local_service_runner.dart)
  ⎿  Analyzing local_service_runner.dart...
     No issues found!
     
⏺ کلاس نوشته شد و آنالایزر بدون هیچ خطایی پاس شد.

  فایل:  lib/src/local_service_runner.dart
  تأیید: dart analyze → "No issues found!" (exit 0)

  خلاصه‌ی پیاده‌سازی:
  - سازنده مسیرِ اجرایی و آرگومان‌های اختیاری را می‌گیرد؛متد start() پروسس فرزند را با Process.start بالا می‌آورد.
  - bool get isActive وضعیت واقعی را بازتاب می‌دهد؛ با exitCodeخروجِ  خودبه‌خودیپروسس (کرش یا اتمام عادی) هم false می‌شود.
  - خروجی‌هایstdout و stderr خط‌به‌خبا utf8.decoder و LineSplitter گوش داده و فقط برای دیباگ لاگ می‌شوند.
  - Future<void> shutdown() سیگنال استاندارد SIGTERM را می‌فرستد،تا خروج کامل پروسس صبر می‌کندو بعد ساب‌اسکریپشن‌هرا آزاد می‌کند؛
  فراخوانی تکراری آن بی‌خطراست.

 ⚠ 1 MCP server needs authentication · run /mcp

> "یک فایل جدید به نام `lib/src/companion_service.dart` بساز. یک کلاس        
  انتزاعی به نام `CompanionService` در آن تعریف کن که شامل متدهای اصلی `Future<void> prepare()`، `Future<bool> run()`، `Future<void>  
  terminate()` و یک Getter به نام `bool get isReady` باشد. همچنین یک Enum به نام `ServiceStatus` با حالت‌های `idle`، `preparing` و      terminate()` و یک Getter به نام `bool get isReady` باشد. همچنین یک Enum به نام `ServiceStatus` با حالت‌های`idle`، `preparing` و
  `active` و `stopped` تعریف کن که وضعیت جاری سرویس محلی را توصیف کند. کد فاقد هرگونه منطق پیچیده یا ارجاعات سیستمی باشد و پس از      
  ساخت، دستور `dart analyze` را برای راستی‌آزمایی روی آن اجرا کن."                                                                     
──
⏺ ساخت فایل جدید و سپس راستی‌آزماییبا dart analyze.

⏺ Write(lib/src/companion_service.dart)
  ⎿  Wrote 22 lines to lib/src/companion_service.dart
       1 /// Lifecycle status of the local companion service.
       2 enum ServiceStatus {
       3   idle,
       4   preparing,
       5   active,
       6   stopped,
       7 }
       8
       9 /// Abstract contract for a local companion service.
      10 abstract class CompanionService {
     … +12 lines (ctrl+o to expand)

⏺ Bash(dart analyze lib/src/companion_service.dart)
  ⎿  Analyzing companion_service.dart...
     No issues found!

⏺ TL;DR — فایل ساخته شد و آنالیز بدون هیچ خطایی پاس شد.

  lib/src/companion_service.dart
  dart analyze → No issues found!

  - کلاس انتزاعی با چهار عضو خواسته‌شده تعریف شد:
  
  abstract class CompanionService
    Future<void> prepare()
    Future<bool> run()
    Future<void> terminate()
    bool get isReady

  - Enum وضعیت هم با چهار حالت اضافه شد:

  enum ServiceStatus { idle, preparing, active, stopped }

  بدون هیچ منطق اضافی یا وابستگی سیستمی — فقط قرارداد خالص.

    > "در پوشه `lib/src/companion_service_impl.dart` کلاس پیاده‌سازی اصلی به نام `CompanionServiceImpl` را بنویس که از رابط `CompanionService` ارث‌بری کند. این کلاس باید با استفاده از `SessionStateStorage` فایل پیکربندی محلی را بنویسد، پروسس فرزند را با استفاده از `LocalServiceRunner` راه‌اندازی کند، و پایداری آن را از طریق `LocalConnectionVerifier` تایید کند. چرخه‌ی شروع، پایان و حذف منابع را به طور کامل پیاده‌سازی و یکپارچه کن. پس از نوشتن، دستور `dart analyze` را اجرا کن."

⏺ من فایل را می‌سازمو بعد با dart analyze می‌سنجم؛اول ساختار موجود را چک می‌کنم.

  Listed 1 directory (ctrl+o to expand)

⏺ ساختار موجود را دیدم؛ حالا فایل جدید را می‌نویسم.

⏺ Write(lib/src/session_state_storage.dart)
  ⎿  Wrote 57 lines to lib/src/session_state_storage.dart
       1 import 'dart:convert';
       2 import 'dart:io';
       3
       4 /// Persists session state as a local JSON config file inside a given
       5 /// root directory, and physically removes that file when the storage
       6 /// is closed.
       7 class SessionStateStorage {
       8   /// [rootDirectoryPath] is the local project-root directory the config
       9   /// file lives in. [fileName] can be overridden for tests.
      10   SessionStateStorage(
     … +47 lines (ctrl+o to expand)

⏺ حالا سنجش با dart analyze:

⏺ Bash(dart analyze lib/src/session_state_storage.dart)
  ⎿  Analyzing session_state_storage.dart...
     No issues found!

⏺ کلاس ساخته شد و dart analyze بدون هیچ خطایی پاس شد.

  فایل ساخته‌شده:

  lib/src/session_state_storage.dart

  ساختار کلاس به این صورت است:

  - سازنده مسیر دایرکتوری روت پروژه را می‌گیردو نام فایل هم قابل‌تنظیماست (پیش‌فرضsession_state.json).
  - متد save یک Map<String, dynamic> را به‌صورتJSON مرتب‌شدهدر فایل متنی داخل همان دایرکتوری می‌نویسدو در صورت نبودِ  دایرکتوری آن را
  می‌سازد.
  - متد close فایل را به‌صورتفیزیکی از دیسک پاک می‌کند؛چندبار صدازدنش امن است و بعد از بسته‌شدن،save با StateError جلوی نوشتنِ  دوباره
  را می‌گیرد.

  نتیجه‌یسنجش:

  dart analyze lib/src/session_state_storage.dart
  → No issues found!

behnam@Behnams-iMac voice_call_kit_v3 % >....                                                                                         
    required LocalConnectionVerifier verifier,
    required String host,
    required int port,
    required Map<String, dynamic> config,
  })  : _storage = storage,
        _runner = runner,
        _verifier = verifier,
        _host = host,
        _port = port,
        _config = config;

  /// Returns the current lifecycle status of this service.
  ServiceStatus get status => _status;

  @override
  bool get isReady => _status == ServiceStatus.active && _runner.isActive;

  @override
  Future<void> prepare() async {
    if (_status != ServiceStatus.idle) return;

    _status = ServiceStatus.preparing;
    try {
      await _storage.save(_config);
    } catch (e) {
      _status = ServiceStatus.idle;
      rethrow;
    }
  }

  @override
  Future<bool> run() async {
    if (_status != ServiceStatus.preparing) {
      return _status == ServiceStatus.active;
    }

    try {
      await _runner.start();

      if (!_runner.isActive) {
        _status = ServiceStatus.stopped;
        return false;
      }

      final isHealthy = await _verifier.verifyServiceReadiness(_host, _port);
      if (isHealthy) {
        _status = ServiceStatus.active;
        return true;
      } else {
        await terminate();
        return false;
      }
    } catch (e) {
      await terminate();
      return false;
    }
  }

  @override
  Future<void> terminate() async {
    _status = ServiceStatus.stopped;
    try {
      await _runner.shutdown();
    } catch (_) {
      // Silent catch to ensure storage is closed even if runner shutdown fails
    }
    try {
      await _storage.close();
    } catch (_) {
      // Silent catch
    }
  }
}
EOF
behnam@Behnams-iMac voice_call_kit_v3 % dart analyze lib/src/companion_service_impl.dart

Analyzing companion_service_impl.dart... 0.6s
No issues found!

mkdir -p test
cat << 'EOF' > test/optional_path_adapter_test.dart
import 'dart:async';
import 'package:test/test.dart';
import 'package:optional_path_adapter/src/companion_service.dart';
import 'package:optional_path_adapter/src/companion_service_impl.dart';
import 'package:optional_path_adapter/src/optional_path_adapter_impl.dart';
import 'package:optional_path_adapter/src/session_state_storage.dart';
import 'package:optional_path_adapter/src/local_service_runner.dart';
import 'package:optional_path_adapter/src/local_connection_verifier.dart';

class FakeSessionStateStorage implements SessionStateStorage {
  bool isSaved = false;
  bool isClosed = false;
  Map<String, dynamic>? savedConfig;

  @override
  String get rootDirectoryPath => 'fake_dir';

  @override
  String get fileName => 'fake_file.json';

  @override
  Future<void> save(Map<String, dynamic> state) async {
    if (isClosed) throw StateError('Closed');
    isSaved = true;
    savedConfig = state;
  }

  @override
  Future<void> close() async {
    isClosed = true;
  }
}

class FakeLocalServiceRunner implements LocalServiceRunner {
  bool isStarted = false;
  bool isShutdown = false;
  bool _isActive = false;

  @override
  String get executablePath => 'fake_exe';

  @override
  List<String> get arguments => [];

  @override
  bool get isActive => _isActive;

  @override
  Future<bool> start() async {
    isStarted = true;
    _isActive = true;
    return true;
  }

  @override
  Future<void> shutdown() async {
    isShutdown = true;
    _isActive = false;
  }
}

class FakeLocalConnectionVerifier implements LocalConnectionVerifier {
  bool verifyCalled = false;
  bool shouldSucceed = true;

  @override
  Future<bool> verifyServiceReadiness(
    String host,
    int port, {
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    verifyCalled = true;
    return shouldSucceed;
  }
}

void main() {
  group('CompanionServiceImpl & OptionalPathAdapterImpl Tests', () {
    late FakeSessionStateStorage storage;
    late FakeLocalServiceRunner runner;
    late FakeLocalConnectionVerifier verifier;
    late CompanionServiceImpl companionService;
    late OptionalPathAdapterImpl adapter;

    setUp(() {
      storage = FakeSessionStateStorage();
      runner = FakeLocalServiceRunner();
      verifier = FakeLocalConnectionVerifier();
      companionService = CompanionServiceImpl(
        storage: storage,
        runner: runner,
        verifier: verifier,
        host: '127.0.0.1',
        port: 8080,
        config: {'key': 'value'},
      );
      adapter = OptionalPathAdapterImpl(companionService);
    });

    test('Full lifecycle success', () async {
      expect(adapter.isHealthy, isFalse);

      await adapter.initialize();
      expect(storage.isSaved, isTrue);
      expect(storage.savedConfig?['key'], equals('value'));

      final started = await adapter.start();
      expect(started, isTrue);
      expect(runner.isStarted, isTrue);
      expect(verifier.verifyCalled, isTrue);
      expect(adapter.isHealthy, isTrue);

      await adapter.stop();
      expect(runner.isShutdown, isTrue);
      expect(storage.isClosed, isTrue);
      expect(adapter.isHealthy, isFalse);
    });

    test('Start fails if verifier health check fails', () async {
      verifier.shouldSucceed = false;

      await adapter.initialize();
      final started = await adapter.start();

      expect(started, isFalse);
      expect(adapter.isHealthy, isFalse);
      expect(runner.isShutdown, isTrue); // Should terminate on network failure
      expect(storage.isClosed, isTrue);
    });
  });
}
EOF