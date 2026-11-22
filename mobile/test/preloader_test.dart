import 'package:flutter_test/flutter_test.dart';
import 'package:theoremfeed/services/preloader.dart';

void main() {
  test('preloads the next 3, each once, one at a time, ignoring failures', () async {
    final calls = <String>[];
    var running = 0, maxRunning = 0;
    final p = Preloader((id) async {
      running++;
      maxRunning = running > maxRunning ? running : maxRunning;
      calls.add(id);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      running--;
      if (id == 'c') throw StateError('blocked');
    });
    final ids = ['a', 'b', 'c', 'd', 'e', 'f'];
    p.around(ids, 0);
    p.around(ids, 0); // no duplicates
    await p.idle;
    expect(calls, ['b', 'c', 'd']);
    p.around(ids, 2);
    p.around(ids, 5); // nothing beyond the end
    await p.idle;
    expect(calls, ['b', 'c', 'd', 'e', 'f']);
    expect(maxRunning, 1);
  });
}
