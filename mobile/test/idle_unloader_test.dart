import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/services/idle_unloader.dart';

void main() {
  test('unloads only after the timeout with nothing running; any use resets it', () {
    fakeAsync((async) {
      var unloads = 0;
      final u = IdleUnloader(timeout: const Duration(seconds: 90), onIdle: () async => unloads++);

      u.arm(); // just loaded
      async.elapse(const Duration(seconds: 60));
      expect(unloads, 0);

      // A use in progress for longer than the timeout never triggers an unload.
      u.run(() => Future<void>.delayed(const Duration(seconds: 200)));
      async.elapse(const Duration(seconds: 150));
      expect(unloads, 0);
      expect(u.isBusy, isTrue);
      async.elapse(const Duration(seconds: 50)); // the use finishes exactly now → countdown starts
      async.flushMicrotasks();
      expect(u.isBusy, isFalse);
      expect(u.countdownActive, isTrue);
      async.elapse(const Duration(seconds: 89));
      expect(unloads, 0);
      async.elapse(const Duration(seconds: 2));
      expect(unloads, 1);

      // Back-to-back uses keep it loaded.
      u.arm();
      for (var i = 0; i < 5; i++) {
        async.elapse(const Duration(seconds: 60));
        u.run(() async {});
        async.flushMicrotasks();
      }
      expect(unloads, 1);
      async.elapse(const Duration(seconds: 91));
      expect(unloads, 2);
    });
  });
}
