import 'package:nocterm_unrouter/nocterm_unrouter.dart';
import 'models.dart';

sealed class NitroRoute implements RouteData {
  const NitroRoute();
}

final class RootRoute extends NitroRoute {
  const RootRoute();
  @override
  Uri toUri() => Uri(path: '/');
}

final class CommandRoute extends NitroRoute {
  const CommandRoute(this.command);
  final NitroCommand command;
  @override
  Uri toUri() => Uri(path: command.path);
}
