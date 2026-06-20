import '../../../bridge_spec.dart';
import '../../code_writer.dart';
import '../../generator_metadata.dart';

class CMakeGenerator {
  static String generate(BridgeSpec spec) {
    return CodeFile([
      CodeSnippet(generatedFileHeader('#', sourceUri: spec.sourceUri)),
      const CodeLine('cmake_minimum_required(VERSION 3.10)'),
      const BlankLine(),
      CodeLine('set(NITRO_MODULE_NAME ${spec.lib})'),
      const CodeBlock(
        header: 'add_library(\${\${NITRO_MODULE_NAME}} SHARED',
        body: [
          CodeLine('\${\${NITRO_MODULE_NAME}}_bridge.g.h'),
          CodeLine('# Add your source files here'),
        ],
      ),
      const BlankLine(),
      const CodeBlock(
        header: 'target_link_libraries(\${\${NITRO_MODULE_NAME}}',
        body: [
          CodeLine('android'),
          CodeLine('log'),
        ],
      ),
    ]).render(indentText: '    ');
  }
}
