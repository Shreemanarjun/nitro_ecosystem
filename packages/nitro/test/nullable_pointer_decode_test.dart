import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

// A bridge that could not run the method returns a null NitroOpt* pointer;
// decoding it must give null, not read address 0.
void main() {
  test('null NitroOpt pointers decode to null', () {
    expect(Pointer<NitroOptInt64>.fromAddress(0).decoded, isNull);
    expect(Pointer<NitroOptFloat64>.fromAddress(0).decoded, isNull);
    expect(Pointer<NitroOptBool>.fromAddress(0).decoded, isNull);
  });

  test('set and unset NitroOpt pointers decode their value', () {
    final i = calloc<NitroOptInt64>();
    final d = calloc<NitroOptFloat64>();
    final b = calloc<NitroOptBool>();
    try {
      expect(i.decoded, isNull);
      expect(d.decoded, isNull);
      expect(b.decoded, isNull);
      i.ref
        ..hasValue = 1
        ..value = -5;
      d.ref
        ..hasValue = 1
        ..value = 2.5;
      b.ref
        ..hasValue = 1
        ..value = 1;
      expect(i.decoded, -5);
      expect(d.decoded, 2.5);
      expect(b.decoded, isTrue);
    } finally {
      calloc
        ..free(i)
        ..free(d)
        ..free(b);
    }
  });
}
