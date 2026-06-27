import 'package:nitro_generator/src/generators/code_writer.dart';
import 'package:test/test.dart';

void main() {
  group('CodeWriter', () {
    test('renders typed lines and blank lines', () {
      final out = const CodeFile([
        CodeLine('one'),
        BlankLine(),
        CodeLine('two'),
      ]).render();

      expect(out, 'one\n\ntwo\n');
    });

    test('renders nested blocks with configured indentation', () {
      final out = const CodeFile([
        CodeBlock(
          header: 'block(',
          body: [
            CodeLine('child'),
          ],
        ),
      ]).render(indentText: '    ');

      expect(out, 'block(\n    child\n)\n');
    });
  });
}
