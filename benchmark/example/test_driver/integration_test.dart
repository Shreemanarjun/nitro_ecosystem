// Host-side driver for the benchmark integration test.
//
// The default integrationDriver writes the test's reportData (our benchmark
// JSON) to build/integration_response_data.json, which tool/bench.sh then
// formats and archives.

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
