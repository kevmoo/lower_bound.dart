import 'dart:io';

import 'package:lower_bound/src/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runLowerBoundCli(args);
}
