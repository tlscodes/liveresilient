/// Guards the conditional-export split introduced for web safety.
///
/// On the VM `dart.library.ffi` exists, so the real branch must be selected
/// and the capability constant must say so. The web branch itself is proved by
/// compiling a consumer of this package with dart2js (see PLATFORM-SUPPORT.md
/// in the engine repo); a VM test cannot execute that branch.
import 'package:native_transport/native_transport.dart';
import 'package:test/test.dart';

void main() {
  test('VM selects the ffi branch and reports availability', () {
    expect(isNativeTransportAvailable, isTrue);
  });

  test('platform-independent names are exported from the shared file', () {
    expect(PtStatus.ok, 0);
    expect(PtStatus.nomem, -6);
    expect(ptNativeLaneName, 'pt-native');
    expect(PtException(-1, 'm', 'invalid').toString(), contains('invalid'));
  });
}
