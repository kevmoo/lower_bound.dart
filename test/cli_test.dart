import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:checks/checks.dart';
import 'package:cli_util/cli_util.dart';
import 'package:lower_bound/src/cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';

void main() {
  late String binPath;
  final dartExe =
      dartExecutable ??
      (throw StateError('Could not locate a Dart executable.'));

  setUpAll(() async {
    final libUri = await Isolate.resolvePackageUri(
      Uri.parse('package:lower_bound/lower_bound.dart'),
    );
    var pkgRoot = p.dirname(libUri!.toFilePath());
    for (
      var i = 0;
      i <
          Uri.parse(
                'package:lower_bound/lower_bound.dart',
              ).pathSegments.length -
              1;
      i++
    ) {
      pkgRoot = p.dirname(pkgRoot);
    }
    binPath = p.join(pkgRoot, 'bin', 'lower_bound.dart');
  });

  group('CLI Options & Resolution', () {
    test('displays help with --help and exits 0', () async {
      final out = StringBuffer();
      final exitCode = await runLowerBoundCli(['--help'], stdoutSink: out);
      check(exitCode).equals(0);
      check(out.toString()).contains(
        'Validate Dart package compilation against dependency lower bounds.',
      );
    });

    test('exits 64 on invalid argument', () async {
      final err = StringBuffer();
      final exitCode = await runLowerBoundCli([
        '--non-existent-flag',
      ], stderrSink: err);
      check(exitCode).equals(64);
      check(err.toString()).contains('Could not find an option');
    });

    test('exits 64 on invalid --sdk argument', () async {
      final err = StringBuffer();
      final exitCode = await runLowerBoundCli([
        '--sdk=invalid-sdk-version',
        '.',
      ], stderrSink: err);
      check(exitCode).equals(64);
      check(err.toString()).contains('Invalid --sdk');
    });

    test('exits 66 when target directory does not exist', () async {
      final err = StringBuffer();
      final exitCode = await runLowerBoundCli([
        '/non/existent/directory/path',
      ], stderrSink: err);
      check(exitCode).equals(66);
      check(err.toString()).contains('Directory does not exist');
    });

    test('exits 66 when directory has no pubspec.yaml', () async {
      await d.dir('empty_dir', []).create();

      final err = StringBuffer();
      final exitCode = await runLowerBoundCli([
        p.join(d.sandbox, 'empty_dir'),
      ], stderrSink: err);
      check(exitCode).equals(66);
      check(err.toString()).contains('No pubspec.yaml found');
    });

    test('does not write sticky PR comment when run is clean', () async {
      await d.dir('valid_pkg', [
        d.file('pubspec.yaml', '''
name: valid_pkg
environment:
  sdk: '^3.12.0'
'''),
        d.dir('lib', [d.file('valid_pkg.dart', 'const a = 1;')]),
      ]).create();

      final commentFile = p.join(d.sandbox, 'comment.md');

      final proc = await TestProcess.start(dartExe, [
        binPath,
        '--comment-output=$commentFile',
        '--max-comment-rows=1',
        p.join(d.sandbox, 'valid_pkg'),
      ]);
      await proc.shouldExit(0);

      check(File(commentFile).existsSync()).isFalse();
    });

    test('writes sticky PR comment when run is dirty', () async {
      await d.dir('dirty_pkg', [
        d.file('pubspec.yaml', '''
name: dirty_pkg
environment:
  sdk: '^3.12.0'
dependencies:
  path: ^1.9.0
'''),
        d.dir('lib', [
          d.file('dirty_pkg.dart', '''
import 'package:path/path.dart' as p;
void main() {
  p.thisFunctionDoesNotExistAtFloor();
}
          '''),
        ]),
      ]).create();

      final commentFile = p.join(d.sandbox, 'comment.md');

      final proc = await TestProcess.start(dartExe, [
        binPath,
        '--comment-output=$commentFile',
        '--max-comment-rows=1',
        p.join(d.sandbox, 'dirty_pkg'),
      ]);
      // 70 (ExitCode.software) is also what a `pub get` failure yields, so
      // pin the *reason*: without this the test passes even if the fixture
      // stops exercising the lower-bound analysis path.
      await proc.shouldExit(70);

      final commentContent = File(commentFile).readAsStringSync();
      check(commentContent).contains('<!-- lower-bound-comment-marker -->');
      check(
        commentContent,
      ).contains('## 📦 Dependency Lower-Bound Validation Summary');
      check(commentContent).contains('dirty_pkg');
      check(
        commentContent,
      ).contains('Static Analysis Errors at Dependency Floor');
    });

    test('formats output as JSON with --format=json', () async {
      await d.dir('json_pkg', [
        d.file('pubspec.yaml', '''
name: json_pkg
environment:
  sdk: '^3.12.0'
'''),
        d.dir('lib', [d.file('json_pkg.dart', 'const a = 1;')]),
      ]).create();

      final proc = await TestProcess.start(dartExe, [
        binPath,
        '--format=json',
        p.join(d.sandbox, 'json_pkg'),
      ]);

      final output = await proc.stdout.rest.toList();
      await proc.shouldExit(0);

      final jsonStr = output.join('\n');
      final decoded = jsonDecode(jsonStr) as List;
      check(decoded).length.equals(1);
      final entry = decoded.first as Map<String, dynamic>;
      check(entry['package']).equals('json_pkg');
      check(entry['clean']).equals(true);
    });

    test(
      'expands workspace members when explicit path is workspace root',
      () async {
        await d.dir('explicit_workspace', [
          d.file('pubspec.yaml', '''
name: workspace_root
workspace:
  - member_a
  - member_b
environment:
  sdk: '^3.12.0'
'''),
          d.dir('member_a', [
            d.file('pubspec.yaml', '''
name: member_a
environment:
  sdk: '^3.12.0'
'''),
            d.dir('lib', [d.file('member_a.dart', 'const a = 1;')]),
          ]),
          d.dir('member_b', [
            d.file('pubspec.yaml', '''
name: member_b
environment:
  sdk: '^3.12.0'
'''),
            d.dir('lib', [d.file('member_b.dart', 'const b = 2;')]),
          ]),
        ]).create();

        final out = StringBuffer();
        final exitCode = await runLowerBoundCli([
          p.join(d.sandbox, 'explicit_workspace'),
        ], stdoutSink: out);
        check(exitCode).equals(0);
        check(out.toString()).contains('member_a');
        check(out.toString()).contains('member_b');
      },
    );

    test(
      'validates workspace root package itself and skips publish_to: none test '
      'members when root is publishable',
      () async {
        await d.dir('pkg_with_e2e_workspace', [
          d.file('pubspec.yaml', '''
name: bazel_worker_like
version: 1.0.0
workspace:
  - e2e_test
environment:
  sdk: '^3.12.0'
'''),
          d.dir('lib', [d.file('worker.dart', 'const w = 1;')]),
          d.dir('e2e_test', [
            d.file('pubspec.yaml', '''
name: e2e_test
publish_to: none
resolution: workspace
environment:
  sdk: '^3.12.0'
dependencies:
  bazel_worker_like: any
'''),
            d.dir('lib', [d.file('e2e.dart', 'const e = 1;')]),
          ]),
        ]).create();

        final out = StringBuffer();
        final exitCode = await runLowerBoundCli([
          p.join(d.sandbox, 'pkg_with_e2e_workspace'),
        ], stdoutSink: out);
        check(exitCode).equals(0);
        check(out.toString()).contains('bazel_worker_like');
        check(out.toString()).not((s) => s.contains('e2e_test'));
      },
    );

    test(
      'expands publishable subpackages in pkgs/ monorepo without root pubspec',
      () async {
        await d.dir('pkgs_monorepo', [
          d.dir('pkgs', [
            d.dir('pkg_one', [
              d.file('pubspec.yaml', '''
name: pkg_one
version: 1.0.0
environment:
  sdk: '^3.12.0'
'''),
              d.dir('lib', [d.file('pkg_one.dart', 'const a = 1;')]),
            ]),
            d.dir('_compliance_tests', [
              d.file('pubspec.yaml', '''
name: _compliance_tests
publish_to: none
environment:
  sdk: '^3.12.0'
dependencies:
  pkg_one: any
'''),
              d.dir('lib', [d.file('compliance.dart', 'const c = 1;')]),
            ]),
          ]),
        ]).create();

        final out = StringBuffer();
        final exitCode = await runLowerBoundCli([
          p.join(d.sandbox, 'pkgs_monorepo'),
        ], stdoutSink: out);
        check(exitCode).equals(0);
        check(out.toString()).contains('pkg_one');
        check(out.toString()).not((s) => s.contains('_compliance_tests'));
      },
    );

    test(
      'expands both workspace members and non-workspace pkgs/ subpackages',
      () async {
        await d.dir('hybrid_workspace', [
          d.file('pubspec.yaml', '''
name: hybrid_workspace
publish_to: none
environment:
  sdk: '^3.12.0'
workspace:
  - pkgs/pkg_in_ws
'''),
          d.dir('pkgs', [
            d.dir('pkg_in_ws', [
              d.file('pubspec.yaml', '''
name: pkg_in_ws
version: 1.0.0
resolution: workspace
environment:
  sdk: '^3.12.0'
'''),
              d.dir('lib', [d.file('in_ws.dart', 'const a = 1;')]),
            ]),
            d.dir('pkg_outside_ws', [
              d.file('pubspec.yaml', '''
name: pkg_outside_ws
version: 1.0.0
environment:
  sdk: '^3.12.0'
'''),
              d.dir('lib', [d.file('out_ws.dart', 'const b = 2;')]),
            ]),
          ]),
        ]).create();

        final out = StringBuffer();
        final exitCode = await runLowerBoundCli([
          p.join(d.sandbox, 'hybrid_workspace'),
        ], stdoutSink: out);
        check(exitCode).equals(0);
        check(out.toString()).contains('pkg_in_ws');
        check(out.toString()).contains('pkg_outside_ws');
      },
    );
  });
}
