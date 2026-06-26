abstract interface class CodeNode {
  void writeTo(CodeWriter writer);
}

final class CodeFile implements CodeNode {
  final List<CodeNode> nodes;

  const CodeFile(this.nodes);

  @override
  void writeTo(CodeWriter writer) {
    for (final node in nodes) {
      node.writeTo(writer);
    }
  }

  String render({String indentText = '  '}) {
    final writer = CodeWriter(indentText: indentText);
    writeTo(writer);
    return writer.toString();
  }
}

final class CodeLine implements CodeNode {
  final String value;

  const CodeLine(this.value);

  @override
  void writeTo(CodeWriter writer) {
    writer.line(value);
  }
}

final class BlankLine implements CodeNode {
  const BlankLine();

  @override
  void writeTo(CodeWriter writer) {
    writer.blankLine();
  }
}

final class CodeSnippet implements CodeNode {
  final String value;

  const CodeSnippet(this.value);

  @override
  void writeTo(CodeWriter writer) {
    writer.raw(value);
  }
}

final class CodeBlock implements CodeNode {
  final String header;
  final List<CodeNode> body;
  final String footer;

  const CodeBlock({
    required this.header,
    required this.body,
    this.footer = ')',
  });

  @override
  void writeTo(CodeWriter writer) {
    writer.line(header);
    writer.indent(() {
      for (final node in body) {
        node.writeTo(writer);
      }
    });
    writer.line(footer);
  }
}

final class CodeWriter {
  final StringBuffer _buffer = StringBuffer();
  final String indentText;
  int _indentLevel = 0;

  CodeWriter({this.indentText = '  '});

  void line(String value) {
    if (value.isNotEmpty) {
      _buffer.write(indentText * _indentLevel);
      _buffer.write(value);
    }
    _buffer.writeln();
  }

  void writeln([String value = '']) {
    line(value);
  }

  void blankLine() {
    _buffer.writeln();
  }

  void raw(String value) {
    _buffer.write(value);
  }

  void indent(void Function() writeIndented) {
    _indentLevel++;
    try {
      writeIndented();
    } finally {
      _indentLevel--;
    }
  }

  // ── High-level helpers ───────────────────────────────────────────────────────

  /// Emits `header {`, indented [body], then `}`.
  ///
  ///     writer.block('fun greet()', () {
  ///       writer.line('println("hello")');
  ///     });
  void block(String header, void Function() body) {
    line('$header {');
    indent(body);
    line('}');
  }

  /// Emits an `if` block and an optional `else` block with braces.
  void ifBlock(String condition, void Function() body, [void Function()? elseBody]) {
    if (elseBody == null) {
      block('if ($condition)', body);
    } else {
      line('if ($condition) {');
      indent(body);
      line('} else {');
      indent(elseBody);
      line('}');
    }
  }

  /// Emits [body] only when [condition] is true — no output otherwise.
  void when(bool condition, void Function() body) {
    if (condition) body();
  }

  /// Emits each item in [items] on its own line, separated by [separator].
  ///
  /// The separator is appended to every line except the last.
  void joinLines(Iterable<String> items, {String separator = ','}) {
    final list = items.toList();
    for (var i = 0; i < list.length; i++) {
      line(i < list.length - 1 ? '${list[i]}$separator' : list[i]);
    }
  }

  /// Emits a blank line (alias for [blankLine] that matches the plan API name).
  void blank() => blankLine();

  @override
  String toString() => _buffer.toString();
}
