import 'package:nitro/nitro.dart';
import 'package:test/test.dart';

void main() {
  test('nitro.dart re-exports typed_data symbols used by generated parts', () {
    final list = Int64List.fromList([1, 2, 3]);
    final bytes = ByteData(8)..setInt64(0, list.first, Endian.little);

    expect(bytes.getInt64(0, Endian.little), 1);
  });
}
