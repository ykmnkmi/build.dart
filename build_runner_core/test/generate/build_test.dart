// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:_test_common/common.dart';
import 'package:build/build.dart';
// ignore: implementation_imports
import 'package:build/src/internal.dart';
import 'package:build_config/build_config.dart';
import 'package:build_runner_core/build_runner_core.dart';
import 'package:build_runner_core/src/asset_graph/graph.dart';
import 'package:build_runner_core/src/asset_graph/node.dart';
import 'package:build_runner_core/src/asset_graph/post_process_build_step_id.dart';
import 'package:build_runner_core/src/generate/build_phases.dart';
import 'package:build_runner_core/src/generate/options.dart'
    show defaultNonRootVisibleAssets;
import 'package:built_collection/built_collection.dart';
import 'package:glob/glob.dart';
import 'package:test/test.dart';

void main() {
  /// Basic phases/phase groups which get used in many tests
  final testBuilder = TestBuilder(
    buildExtensions: appendExtension('.copy', from: '.txt'),
  );
  final copyABuilderApplication = applyToRoot(testBuilder);
  final requiresPostProcessBuilderApplication = apply(
    'test_builder',
    [(_) => testBuilder],
    toRoot(),
    appliesBuilders: ['a:post_copy_builder'],
    hideOutput: false,
  );
  final postCopyABuilderApplication = applyPostProcess(
    'a:post_copy_builder',
    (options) => CopyingPostProcessBuilder(
      outputExtension: options.config['extension'] as String? ?? '.post',
    ),
  );
  final globBuilder = GlobbingBuilder(Glob('**.txt'));
  final placeholders = placeholderIdsFor(
    buildPackageGraph({rootPackage('a'): []}),
  );

  group('build', () {
    test('can log within a buildFactory', () async {
      await testPhases(
        [
          apply(
            '',
            [
              (_) {
                log.info('I can log!');
                return TestBuilder(buildExtensions: appendExtension('.1'));
              },
            ],
            toRoot(),
            isOptional: true,
            hideOutput: false,
          ),
        ],
        {'a|web/a.txt': 'a'},
      );
    });

    test('Builder factories are only invoked once per application', () async {
      var invokedCount = 0;
      final packageGraph = buildPackageGraph({
        rootPackage('a'): ['b'],
        package('b'): [],
      });
      await testPhases(
        [
          apply(
            '',
            [
              (_) {
                invokedCount += 1;
                return TestBuilder();
              },
            ],
            toAllPackages(),
            isOptional: false,
            hideOutput: true,
          ),
        ],
        {},
        packageGraph: packageGraph,
      );

      // Once per package, including the SDK.
      expect(invokedCount, 3);
    });

    test('throws an error if the builderFactory fails', () async {
      expect(
        () async => await testPhases(
          [
            apply(
              '',
              [
                (_) {
                  throw StateError('some error');
                },
              ],
              toRoot(),
              isOptional: true,
              hideOutput: false,
            ),
          ],
          {'a|web/a.txt': 'a'},
        ),
        throwsA(const TypeMatcher<CannotBuildException>()),
      );
    });

    test('throws an error if any output extensions match input extensions', () {
      expect(
        testPhases(
          [
            apply(
              '',
              [
                expectAsync1(
                  (_) => TestBuilder(
                    buildExtensions: {
                      '.dart': ['.g.dart', '.json'],
                      '.json': ['.dart'],
                    },
                  ),
                ),
              ],
              toRoot(),
              isOptional: false,
              hideOutput: false,
            ),
          ],
          {},
          status: BuildStatus.failure,
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'TestBuilder.buildExtensions')
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('.json'),
                  contains('.dart'),
                  isNot(contains('.g.dart')),
                ),
              ),
        ),
      );
    });

    test('runs a max of one concurrent action per phase', () async {
      var assets = <String, String>{};
      for (var i = 0; i < 2; i++) {
        assets['a|web/$i.txt'] = '$i';
      }
      var concurrentCount = 0;
      var maxConcurrentCount = 0;
      var reachedMax = Completer<void>();
      await testPhases(
        [
          apply(
            '',
            [
              (_) {
                return TestBuilder(
                  build: (_, _) async {
                    concurrentCount += 1;
                    maxConcurrentCount = math.max(
                      concurrentCount,
                      maxConcurrentCount,
                    );
                    if (concurrentCount >= 1 && !reachedMax.isCompleted) {
                      await Future<void>.delayed(
                        const Duration(milliseconds: 100),
                      );
                      if (!reachedMax.isCompleted) reachedMax.complete(null);
                    }
                    await reachedMax.future;
                    concurrentCount -= 1;
                  },
                );
              },
            ],
            toRoot(),
            isOptional: false,
            hideOutput: false,
          ),
        ],
        assets,
        outputs: {},
      );
      expect(maxConcurrentCount, 1);
    });

    group('with root package inputs', () {
      test('one phase, one builder, one-to-one outputs', () async {
        await testPhases(
          [copyABuilderApplication],
          {'a|web/a.txt': 'a', 'a|lib/b.txt': 'b'},
          outputs: {'a|web/a.txt.copy': 'a', 'a|lib/b.txt.copy': 'b'},
        );
      });

      test('runs once per input not once per output', () async {
        var runs = 0;
        final testBuilder = TestBuilder(
          buildExtensions: {
            '.txt': ['.txt.1', '.txt.2'],
          },
          extraWork: (_, _) {
            ++runs;
          },
        );

        await testPhases(
          [applyToRoot(testBuilder)],
          {'a|web/a.txt': ''},
          outputs: {'a|web/a.txt.1': '', 'a|web/a.txt.2': ''},
        );
        expect(runs, 1);
      });

      test('with a PostProcessBuilder', () async {
        await testPhases(
          [requiresPostProcessBuilderApplication, postCopyABuilderApplication],
          {'a|web/a.txt': 'a', 'a|lib/b.txt': 'b'},
          outputs: {
            'a|web/a.txt.copy': 'a',
            'a|lib/b.txt.copy': 'b',
            r'$$a|web/a.txt.post': 'a',
            r'$$a|lib/b.txt.post': 'b',
          },
        );
      });

      test('with placeholder as input', () async {
        await testPhases(
          [
            applyToRoot(
              PlaceholderBuilder(
                {'lib.txt': 'libText'}.build(),
                inputPlaceholder: r'$lib$',
              ),
            ),
            applyToRoot(
              PlaceholderBuilder(
                {'root.txt': 'rootText'}.build(),
                inputPlaceholder: r'$package$',
              ),
            ),
          ],
          {},
          outputs: {'a|lib/lib.txt': 'libText', 'a|root.txt': 'rootText'},
        );
      });

      test('one phase, one builder, one-to-many outputs', () async {
        await testPhases(
          [
            applyToRoot(
              TestBuilder(
                buildExtensions: appendExtension('.copy', numCopies: 2),
              ),
            ),
          ],
          {'a|web/a.txt': 'a', 'a|lib/b.txt': 'b'},
          outputs: {
            'a|web/a.txt.copy.0': 'a',
            'a|web/a.txt.copy.1': 'a',
            'a|lib/b.txt.copy.0': 'b',
            'a|lib/b.txt.copy.1': 'b',
          },
        );
      });

      test('outputs with ^', () async {
        await testPhases(
          [
            applyToRoot(
              TestBuilder(
                buildExtensions: {
                  '^pubspec.yaml': ['pubspec.yaml.copy'],
                },
              ),
            ),
          ],
          {'a|pubspec.yaml': 'a', 'a|lib/pubspec.yaml': 'a'},
          outputs: {'a|pubspec.yaml.copy': 'a'},
        );
      });

      test('outputs with a capture group', () async {
        await testPhases(
          [
            applyToRoot(
              TestBuilder(
                buildExtensions: {
                  'assets/{{}}.txt': ['lib/src/generated/{{}}.dart'],
                },
              ),
            ),
          ],
          {'a|assets/nested/input/file.txt': 'a'},
          outputs: {'a|lib/src/generated/nested/input/file.dart': 'a'},
        );
      });

      test('recognizes right optional builder with capture groups', () async {
        await testPhases(
          [
            applyToRoot(
              TestBuilder(
                buildExtensions: {
                  'assets/{{}}.txt': ['lib/src/generated/{{}}.dart'],
                },
              ),
              isOptional: true,
            ),
            applyToRoot(
              TestBuilder(
                buildExtensions: {
                  '.dart': ['.copy.dart'],
                },
              ),
            ),
          ],
          {'a|assets/nested/input/file.txt': 'a'},
          outputs: {
            'a|lib/src/generated/nested/input/file.dart': 'a',
            'a|lib/src/generated/nested/input/file.copy.dart': 'a',
          },
        );
      });

      test(
        'optional build actions don\'t run if their outputs aren\'t read',
        () async {
          await testPhases(
            [
              apply(
                '',
                [(_) => TestBuilder(buildExtensions: appendExtension('.1'))],
                toRoot(),
                isOptional: true,
              ),
              apply(
                'a:only_on_1',
                [
                  (_) => TestBuilder(
                    buildExtensions: appendExtension('.copy', from: '.1'),
                  ),
                ],
                toRoot(),
                isOptional: true,
              ),
            ],
            {'a|lib/a.txt': 'a'},
            outputs: {},
          );
        },
      );

      test('optional build actions do run if their outputs are read', () async {
        await testPhases(
          [
            apply(
              '',
              [(_) => TestBuilder(buildExtensions: appendExtension('.1'))],
              toRoot(),
              isOptional: true,
              hideOutput: false,
            ),
            apply(
              '',
              [
                (_) =>
                    TestBuilder(buildExtensions: replaceExtension('.1', '.2')),
              ],
              toRoot(),
              isOptional: true,
              hideOutput: false,
            ),
            apply(
              '',
              [
                (_) =>
                    TestBuilder(buildExtensions: replaceExtension('.2', '.3')),
              ],
              toRoot(),
              hideOutput: false,
            ),
          ],
          {'a|web/a.txt': 'a'},
          outputs: {
            'a|web/a.txt.1': 'a',
            'a|web/a.txt.2': 'a',
            'a|web/a.txt.3': 'a',
          },
        );
      });

      test('multiple mixed build actions with custom build config', () async {
        var builders = [
          copyABuilderApplication,
          apply(
            'a:clone_txt',
            [(_) => TestBuilder(buildExtensions: appendExtension('.clone'))],
            toRoot(),
            isOptional: true,
            hideOutput: false,
            appliesBuilders: ['a:post_copy_builder'],
          ),
          apply(
            'a:copy_web_clones',
            [
              (_) => TestBuilder(
                buildExtensions: appendExtension('.copy', numCopies: 2),
              ),
            ],
            toRoot(),
            hideOutput: false,
          ),
          postCopyABuilderApplication,
        ];
        await testPhases(
          builders,
          {
            'a|web/a.txt': 'a',
            'a|lib/b.txt': 'b',
            'a|build.yaml': r'''
targets:
  a:
    builders:
      a:clone.txt:
        generate_for:
          - "**/*.txt"
      a:copy_web_clones:
        generate_for:
          - web/*.txt.clone
      a:post_copy_builder:
        options:
          extension: .custom.post
        generate_for:
          - web/*.txt
''',
          },
          outputs: {
            'a|web/a.txt.copy': 'a',
            'a|web/a.txt.clone': 'a',
            'a|lib/b.txt.copy': 'b',
            // No b.txt.clone since nothing else read it and its optional.
            'a|web/a.txt.clone.copy.0': 'a',
            'a|web/a.txt.clone.copy.1': 'a',
            r'$$a|web/a.txt.custom.post': 'a',
          },
        );
      });

      test('allows running on generated inputs that do not match target '
          'source globx', () async {
        var builders = [
          applyToRoot(
            TestBuilder(buildExtensions: appendExtension('.1', from: '.txt')),
          ),
          applyToRoot(
            TestBuilder(buildExtensions: appendExtension('.2', from: '.1')),
          ),
        ];
        await testPhases(
          builders,
          {
            'a|lib/a.txt': 'a',
            'a|build.yaml': r'''
targets:
  $default:
    sources:
      - lib/*.txt
''',
          },
          outputs: {'a|lib/a.txt.1': 'a', 'a|lib/a.txt.1.2': 'a'},
        );
      });

      test('early step touches a not-yet-generated asset', () async {
        var copyId = AssetId('a', 'lib/file.a.copy');
        var builders = [
          applyToRoot(
            TestBuilder(
              buildExtensions: appendExtension('.copy', from: '.b'),
              extraWork: (buildStep, _) => buildStep.canRead(copyId),
            ),
          ),
          applyToRoot(
            TestBuilder(buildExtensions: appendExtension('.copy', from: '.a')),
          ),
          applyToRoot(
            TestBuilder(
              buildExtensions: appendExtension('.exists', from: '.a'),
              build: writeCanRead(copyId),
            ),
          ),
        ];
        await testPhases(
          builders,
          {'a|lib/file.a': 'a', 'a|lib/file.b': 'b'},
          outputs: {
            'a|lib/file.a.copy': 'a',
            'a|lib/file.b.copy': 'b',
            'a|lib/file.a.exists': 'true',
          },
        );
      });

      test('asset is deleted mid-build, use cached canRead result', () async {
        var aTxtId = AssetId('a', 'lib/file.a');
        var ready = Completer<void>();
        var firstBuilder = TestBuilder(
          buildExtensions: appendExtension('.exists', from: '.a'),
          build: writeCanRead(aTxtId),
        );
        var builders = [
          applyToRoot(firstBuilder),
          applyToRoot(
            TestBuilder(
              buildExtensions: appendExtension('.exists', from: '.b'),
              build: (_, _) => ready.future,
              extraWork: writeCanRead(aTxtId),
            ),
          ),
        ];

        // Do an first build so a reader is created.
        final result = await testPhases(builders, {'unused|lib/unused.a': ''});

        // After the first builder runs, delete the asset from the reader and
        // allow the 2nd builder to run.
        unawaited(
          firstBuilder.buildsCompleted.first.then((id) {
            result.readerWriter.testing.delete(aTxtId);
            ready.complete();
          }),
        );

        await testPhases(
          builders,
          {'a|lib/file.a': '', 'a|lib/file.b': ''},
          resumeFrom: result,
          outputs: {
            'a|lib/file.a.exists': 'true',
            'a|lib/file.b.exists': 'true',
          },
        );
      });

      test('pre-existing outputs', () async {
        final result = await testPhases(
          [
            copyABuilderApplication,
            applyToRoot(
              TestBuilder(
                buildExtensions: appendExtension('.clone', from: '.copy'),
              ),
            ),
          ],
          {'a|web/a.txt': 'a', 'a|web/a.txt.copy': 'a'},
          outputs: {'a|web/a.txt.copy': 'a', 'a|web/a.txt.copy.clone': 'a'},
          deleteFilesByDefault: true,
        );

        var graphId = makeAssetId('a|$assetGraphPath');
        expect(result.readerWriter.testing.exists(graphId), isTrue);
        var cachedGraph = AssetGraph.deserialize(
          result.readerWriter.testing.readBytes(graphId),
        );
        expect(
          cachedGraph.allNodes.map((node) => node.id),
          unorderedEquals([
            makeAssetId('a|web/a.txt'),
            makeAssetId('a|web/a.txt.copy'),
            makeAssetId('a|web/a.txt.copy.clone'),
            ...placeholders,
            makeAssetId('a|.dart_tool/package_config.json'),
          ]),
        );
        expect(cachedGraph.sources, [makeAssetId('a|web/a.txt')]);
        expect(
          cachedGraph.outputs,
          unorderedEquals([
            makeAssetId('a|web/a.txt.copy'),
            makeAssetId('a|web/a.txt.copy.clone'),
          ]),
        );
      });

      test('in low resources mode', () async {
        await testPhases(
          [copyABuilderApplication],
          {'a|web/a.txt': 'a', 'a|lib/b.txt': 'b'},
          outputs: {'a|web/a.txt.copy': 'a', 'a|lib/b.txt.copy': 'b'},
          enableLowResourcesMode: true,
        );
      });

      test('previous outputs are cleaned up', () async {
        final result = await testPhases(
          [copyABuilderApplication],
          {'a|web/a.txt': 'a'},
          outputs: {'a|web/a.txt.copy': 'a'},
        );

        var copyId = makeAssetId('a|web/a.txt.copy');

        var canReadInBuild = Completer<bool>();
        var blockingCompleter = Completer<void>();
        var builder = TestBuilder(
          buildExtensions: appendExtension('.copy', from: '.txt'),
          build: (buildStep, _) async {
            canReadInBuild.complete(await buildStep.canRead(copyId));
            await buildStep.writeAsString(
              copyId,
              await buildStep.readAsString(buildStep.inputId),
            );
            await blockingCompleter.future;
          },
        );
        var done = testPhases(
          [applyToRoot(builder)],
          {'a|web/a.txt': 'b'},
          resumeFrom: result,
          outputs: {'a|web/a.txt.copy': 'b'},
        );

        // Before the build starts we should still see the asset, we haven't
        // actually deleted it yet.
        expect(result.readerWriter.testing.exists(copyId), isTrue);

        // But we should delete it before actually running the builder.
        var inputId = makeAssetId('a|web/a.txt');
        await builder.buildInputs.firstWhere((id) => id == inputId);

        // Because of write caching, it's not deleted from `readerWriter`.
        expect(result.readerWriter.testing.exists(copyId), isTrue);
        // ...but it is gone from the point of view of the build.
        expect(await canReadInBuild.future, isFalse);

        // Now let the build finish.
        blockingCompleter.complete();
        await done;
      });

      test('does not build hidden non-lib assets by default', () async {
        final result = await testPhases(
          [applyToRoot(testBuilder, hideOutput: true)],
          {'a|example/a.txt': 'a', 'a|lib/b.txt': 'b'},
          checkBuildStatus: false,
          buildDirs: {BuildDirectory('web')},
        );

        checkBuild(
          result.buildResult,
          readerWriter: result.readerWriter,
          outputs: {r'$$a|lib/b.txt.copy': 'b'},
        );
      });

      test('builds hidden asset forming a custom public source', () async {
        final result = await testPhases(
          [applyToRoot(testBuilder, hideOutput: true)],
          {
            'a|include/a.txt': 'a',
            'a|lib/b.txt': 'b',
            'a|build.yaml': '''
additional_public_assets:
  - include/**
''',
          },
          checkBuildStatus: false,
          buildDirs: {BuildDirectory('web')},
        );

        checkBuild(
          result.buildResult,
          readerWriter: result.readerWriter,
          outputs: {r'$$a|include/a.txt.copy': 'a', r'$$a|lib/b.txt.copy': 'b'},
        );
      });
    });

    group('reading assets outside of the root package', () {
      test('can read public non-lib assets', () async {
        final packageGraph = buildPackageGraph({
          rootPackage('a', path: 'a/'): ['b'],
          package('b', path: 'a/b'): [],
        });

        final builder = TestBuilder(
          build: copyFrom(makeAssetId('b|test/foo.bar')),
        );

        await testPhases(
          [
            apply('', [(_) => builder], toPackage('a')),
          ],
          {
            'a|lib/a.foo': '',
            'b|test/foo.bar': 'content',
            'b|build.yaml': '''
additional_public_assets:
  - test/**
''',
          },
          packageGraph: packageGraph,
          outputs: {r'$$a|lib/a.foo.copy': 'content'},
        );
      });

      test('reading private assets throws InvalidInputException', () {
        final packageGraph = buildPackageGraph({
          rootPackage('a', path: 'a/'): ['b'],
          package('b', path: 'a/b'): [],
        });

        final builder = TestBuilder(
          buildExtensions: const {
            '.txt': ['.copy'],
          },
          build: (step, _) {
            final invalidInput = AssetId.parse('b|test/my_test.dart');

            expect(step.canRead(invalidInput), completion(isFalse));
            return expectLater(
              () => step.readAsBytes(invalidInput),
              throwsA(
                isA<InvalidInputException>().having(
                  (e) => e.allowedGlobs,
                  'allowedGlobs',
                  defaultNonRootVisibleAssets,
                ),
              ),
            );
          },
        );

        return testPhases(
          [
            apply('', [(_) => builder], toPackage('a')),
          ],
          {'a|lib/foo.txt': "doesn't matter"},
          packageGraph: packageGraph,
          outputs: {},
        );
      });

      test('canRead doesn\'t throw for invalid inputs or missing packages', () {
        final packageGraph = buildPackageGraph({
          rootPackage('a', path: 'a/'): ['b'],
          package('b', path: 'a/b'): [],
        });

        final builder = TestBuilder(
          buildExtensions: const {
            '.txt': ['.copy'],
          },
          build: (step, _) {
            expect(
              step.canRead(AssetId('b', 'test/my_test.dart')),
              completion(isFalse),
            );
            expect(
              step.canRead(AssetId('invalid', 'foo.dart')),
              completion(isFalse),
            );
          },
        );

        return testPhases(
          [
            apply('', [(_) => builder], toPackage('a')),
          ],
          {'a|lib/foo.txt': "doesn't matter"},
          packageGraph: packageGraph,
          outputs: {},
        );
      });
    });

    test(
      'skips builders which would output files in non-root packages',
      () async {
        final packageGraph = buildPackageGraph({
          rootPackage('a', path: 'a/'): ['b'],
          package('b', path: 'a/b'): [],
        });
        await testPhases(
          [
            apply(
              '',
              [(_) => TestBuilder()],
              toPackage('b'),
              hideOutput: false,
            ),
          ],
          {'b|lib/b.txt': 'b'},
          packageGraph: packageGraph,
          outputs: {},
        );
      },
    );

    group('with `hideOutput: true`', () {
      late PackageGraph packageGraph;

      setUp(() {
        packageGraph = buildPackageGraph({
          rootPackage('a', path: 'a/'): ['b'],
          package('b', path: 'a/b/'): [],
        });
      });
      test('can output files in non-root packages', () async {
        await testPhases(
          [
            apply(
              '',
              [(_) => TestBuilder()],
              toPackage('b'),
              hideOutput: true,
              appliesBuilders: ['a:post_copy_builder'],
            ),
            postCopyABuilderApplication,
          ],
          {'b|lib/b.txt': 'b'},
          packageGraph: packageGraph,
          outputs: {r'$$b|lib/b.txt.copy': 'b', r'$$b|lib/b.txt.post': 'b'},
        );
      });

      test('handles mixed hidden and non-hidden outputs', () async {
        await testPhases(
          [
            applyToRoot(TestBuilder()),
            applyToRoot(
              TestBuilder(buildExtensions: appendExtension('.hiddencopy')),
              hideOutput: true,
            ),
          ],
          {'a|lib/a.txt': 'a'},
          packageGraph: packageGraph,
          outputs: {
            r'$$a|lib/a.txt.hiddencopy': 'a',
            r'$$a|lib/a.txt.copy.hiddencopy': 'a',
            r'a|lib/a.txt.copy': 'a',
          },
        );
      });

      test('allows reading hidden outputs from another package to create '
          'a non-hidden output', () async {
        await testPhases(
          [
            apply(
              'hidden_on_b',
              [(_) => TestBuilder()],
              toPackage('b'),
              hideOutput: true,
            ),
            applyToRoot(
              TestBuilder(
                buildExtensions: appendExtension('.check_can_read'),
                build: writeCanRead(makeAssetId('b|lib/b.txt.copy')),
              ),
            ),
          ],
          {'a|lib/a.txt': 'a', 'b|lib/b.txt': 'b'},
          packageGraph: packageGraph,
          outputs: {
            r'$$b|lib/b.txt.copy': 'b',
            r'a|lib/a.txt.check_can_read': 'true',
          },
        );
      });

      test('allows reading hidden outputs from same package to create '
          'a non-hidden output', () async {
        await testPhases(
          [
            applyToRoot(TestBuilder(), hideOutput: true),
            applyToRoot(
              TestBuilder(
                buildExtensions: appendExtension('.check_can_read'),
                build: writeCanRead(makeAssetId('a|lib/a.txt.copy')),
              ),
            ),
          ],
          {'a|lib/a.txt': 'a'},
          packageGraph: packageGraph,
          outputs: {
            r'$$a|lib/a.txt.copy': 'a',
            r'a|lib/a.txt.copy.check_can_read': 'true',
            r'a|lib/a.txt.check_can_read': 'true',
          },
        );
      });

      test('Will not delete from non-root packages', () async {
        await testPhases(
          [
            apply('', [(_) => TestBuilder()], toPackage('b'), hideOutput: true),
          ],
          {
            'b|lib/b.txt': 'b',
            'a|.dart_tool/build/generated/b/lib/b.txt.copy': 'b',
          },
          packageGraph: packageGraph,
          outputs: {r'$$b|lib/b.txt.copy': 'b'},
          onDelete: (AssetId assetId) {
            if (assetId.package != 'a') {
              throw StateError(
                'Should not delete outside of package:a, '
                'tried to delete $assetId',
              );
            }
          },
        );
      });
    });

    test('can read files from external packages', () async {
      var packageGraph = buildPackageGraph({
        rootPackage('a'): ['b'],
        package('b'): [],
      });

      var builders = [
        apply(
          '',
          [
            (_) => TestBuilder(
              extraWork:
                  (buildStep, _) =>
                      buildStep.canRead(makeAssetId('b|lib/b.txt')),
            ),
          ],
          toRoot(),
          hideOutput: false,
        ),
      ];
      await testPhases(
        builders,
        {'a|lib/a.txt': 'a', 'b|lib/b.txt': 'b'},
        outputs: {'a|lib/a.txt.copy': 'a'},
        packageGraph: packageGraph,
      );
    });

    test('can glob files from packages', () async {
      final packageGraph = buildPackageGraph({
        rootPackage('a', path: 'a/'): ['b'],
        package('b', path: 'a/b/'): [],
      });

      var builders = [
        apply('', [(_) => globBuilder], toRoot(), hideOutput: true),
        apply('', [(_) => globBuilder], toPackage('b'), hideOutput: true),
      ];

      await testPhases(
        builders,
        {
          'a|lib/a.globPlaceholder': '',
          'a|lib/a.txt': '',
          'a|lib/b.txt': '',
          'a|web/a.txt': '',
          'b|lib/b.globPlaceholder': '',
          'b|lib/c.txt': '',
          'b|lib/d.txt': '',
          'b|web/b.txt': '',
        },
        outputs: {
          r'$$a|lib/a.matchingFiles': 'a|lib/a.txt\na|lib/b.txt\na|web/a.txt',
          r'$$b|lib/b.matchingFiles': 'b|lib/c.txt\nb|lib/d.txt',
        },
        packageGraph: packageGraph,
      );
    });

    test('can glob files with excludes applied', () async {
      await testPhases(
        [applyToRoot(globBuilder)],
        {
          'a|lib/a/1.txt': '',
          'a|lib/a/2.txt': '',
          'a|lib/b/1.txt': '',
          'a|lib/b/2.txt': '',
          'a|lib/test.globPlaceholder': '',
          'a|build.yaml': r'''
targets:
  a:
    sources:
      exclude:
        - lib/a/**
''',
        },
        outputs: {'a|lib/test.matchingFiles': 'a|lib/b/1.txt\na|lib/b/2.txt'},
      );
    });

    test('can build on files outside the hardcoded sources', () async {
      await testPhases(
        [applyToRoot(TestBuilder())],
        {
          'a|test_files/a.txt': 'a',
          'a|build.yaml': '''
targets:
  a:
    sources:
      - test_files/**
''',
        },
        outputs: {'a|test_files/a.txt.copy': 'a'},
      );
    });

    test('can\'t read files in .dart_tool', () async {
      await testPhases(
        [
          apply('', [
            (_) => TestBuilder(
              build: copyFrom(makeAssetId('a|.dart_tool/any_file')),
            ),
          ], toRoot()),
        ],
        {'a|lib/a.txt': 'a', 'a|.dart_tool/any_file': 'content'},
        status: BuildStatus.failure,
      );
    });

    test(
      'Overdeclared outputs are not treated as inputs to later steps',
      () async {
        var builders = [
          applyToRoot(
            TestBuilder(
              buildExtensions: appendExtension('.unexpected'),
              build: (_, _) {},
            ),
          ),
          applyToRoot(
            TestBuilder(buildExtensions: appendExtension('.expected')),
          ),
          applyToRoot(TestBuilder()),
        ];
        await testPhases(
          builders,
          {'a|lib/a.txt': 'a'},
          outputs: {
            'a|lib/a.txt.copy': 'a',
            'a|lib/a.txt.expected': 'a',
            'a|lib/a.txt.expected.copy': 'a',
          },
        );
      },
    );

    test('can build files from one dir when building another dir', () async {
      await testPhases(
        [
          applyToRoot(
            TestBuilder(),
            generateFor: const InputSet(include: ['test/*.txt']),
            hideOutput: true,
          ),
          applyToRoot(
            TestBuilder(
              buildExtensions: appendExtension('.copy', from: '.txt'),
              extraWork: (buildStep, _) async {
                // Should not trigger a.txt.copy to be built.
                await buildStep.readAsString(AssetId('a', 'test/a.txt'));
                // Should trigger b.txt.copy to be built.
                await buildStep.readAsString(AssetId('a', 'test/b.txt.copy'));
              },
            ),
            generateFor: const InputSet(include: ['web/*.txt']),
            hideOutput: true,
          ),
        ],
        {'a|test/a.txt': 'a', 'a|test/b.txt': 'b', 'a|web/a.txt': 'a'},
        outputs: {r'$$a|web/a.txt.copy': 'a', r'$$a|test/b.txt.copy': 'b'},
        buildDirs: {BuildDirectory('web')},
        verbose: true,
      );
    });

    test(
      'build to source builders are always ran regardless of buildDirs',
      () async {
        await testPhases(
          [
            applyToRoot(
              TestBuilder(),
              generateFor: const InputSet(include: ['**/*.txt']),
              hideOutput: false,
            ),
          ],
          {'a|test/a.txt': 'a', 'a|web/a.txt': 'a'},
          outputs: {r'a|test/a.txt.copy': 'a', r'a|web/a.txt.copy': 'a'},
          buildDirs: {BuildDirectory('web')},
          verbose: true,
        );
      },
    );

    test('can output performance logs', () async {
      final result = await testPhases(
        [
          apply(
            'test_builder',
            [(_) => TestBuilder()],
            toRoot(),
            isOptional: false,
            hideOutput: false,
          ),
        ],
        {'a|web/a.txt': 'a'},
        outputs: {'a|web/a.txt.copy': 'a'},
        logPerformanceDir: 'perf',
      );
      var logs =
          await result.readerWriter.assetFinder.find(Glob('perf/**')).toList();
      expect(logs.length, 1);
      var perf = BuildPerformance.fromJson(
        jsonDecode(await result.readerWriter.readAsString(logs.first))
            as Map<String, dynamic>,
      );
      expect(perf.phases.length, 1);
      expect(perf.phases.first.builderKeys, equals(['test_builder']));
    });

    group('buildFilters', () {
      var packageGraphWithDep = buildPackageGraph({
        package('b'): [],
        rootPackage('a'): ['b'],
      });

      test('explicit files by uri and path', () async {
        await testPhases(
          [
            apply(
              '',
              [(_) => TestBuilder()],
              toAllPackages(),
              defaultGenerateFor: const InputSet(include: ['**/*.txt']),
            ),
          ],
          {
            'a|lib/a.txt': '',
            'a|web/a.txt': '',
            'a|web/a0.txt': '',
            'b|lib/b.txt': '',
            'b|lib/b0.txt': '',
          },
          outputs: {
            r'$$a|lib/a.txt.copy': '',
            r'$$a|web/a.txt.copy': '',
            r'$$b|lib/b.txt.copy': '',
          },
          buildFilters: {
            BuildFilter.fromArg('web/a.txt.copy', 'a'),
            BuildFilter.fromArg('package:a/a.txt.copy', 'a'),
            BuildFilter.fromArg('package:b/b.txt.copy', 'a'),
          },
          verbose: true,
          packageGraph: packageGraphWithDep,
        );
      });

      test('with package globs', () async {
        await testPhases(
          [
            apply(
              '',
              [(_) => TestBuilder()],
              toAllPackages(),
              defaultGenerateFor: const InputSet(include: ['**/*.txt']),
            ),
          ],
          {'a|lib/a.txt': '', 'b|lib/a.txt': ''},
          outputs: {r'$$a|lib/a.txt.copy': '', r'$$b|lib/a.txt.copy': ''},
          buildFilters: {BuildFilter.fromArg('package:*/a.txt.copy', 'a')},
          verbose: true,
          packageGraph: packageGraphWithDep,
        );
      });

      test('with path globs', () async {
        await testPhases(
          [
            apply(
              '',
              [(_) => TestBuilder()],
              toAllPackages(),
              defaultGenerateFor: const InputSet(include: ['**/*.txt']),
            ),
          ],
          {
            'a|lib/a.txt': '',
            'a|lib/a0.txt': '',
            'a|web/a.txt': '',
            'a|web/a1.txt': '',
            'b|lib/b.txt': '',
            'b|lib/b2.txt': '',
          },
          outputs: {
            r'$$a|lib/a0.txt.copy': '',
            r'$$a|web/a1.txt.copy': '',
            r'$$b|lib/b2.txt.copy': '',
          },
          buildFilters: {
            BuildFilter.fromArg('package:a/*0.txt.copy', 'a'),
            BuildFilter.fromArg('web/*1.txt.copy', 'a'),
            BuildFilter.fromArg('package:b/*2.txt.copy', 'a'),
          },
          verbose: true,
          packageGraph: packageGraphWithDep,
        );
      });

      test('with package and path globs', () async {
        await testPhases(
          [
            apply(
              '',
              [(_) => TestBuilder()],
              toAllPackages(),
              defaultGenerateFor: const InputSet(include: ['**/*.txt']),
            ),
          ],
          {'a|lib/a.txt': '', 'b|lib/b.txt': ''},
          outputs: {r'$$a|lib/a.txt.copy': '', r'$$b|lib/b.txt.copy': ''},
          buildFilters: {BuildFilter.fromArg('package:*/*.txt.copy', 'a')},
          verbose: true,
          packageGraph: packageGraphWithDep,
        );
      });
    });
  });

  test('tracks dependency graph in a asset_graph.json file', () async {
    final result = await testPhases(
      [requiresPostProcessBuilderApplication, postCopyABuilderApplication],
      {'a|web/a.txt': 'a', 'a|lib/b.txt': 'b'},
      outputs: {
        'a|web/a.txt.copy': 'a',
        'a|lib/b.txt.copy': 'b',
        r'$$a|web/a.txt.post': 'a',
        r'$$a|lib/b.txt.post': 'b',
      },
    );

    var graphId = makeAssetId('a|$assetGraphPath');
    expect(result.readerWriter.testing.exists(graphId), isTrue);
    var cachedGraph = AssetGraph.deserialize(
      result.readerWriter.testing.readBytes(graphId),
    );

    var expectedGraph = await AssetGraph.build(
      BuildPhases([]),
      <AssetId>{},
      {makeAssetId('a|.dart_tool/package_config.json')},
      buildPackageGraph({rootPackage('a'): []}),
      result.readerWriter,
    );

    // Source nodes
    var aId = AssetId.parse('a|web/a.txt');
    var aSourceNode = AssetNode.source(aId, digest: computeDigest(aId, 'a'));
    var bId = AssetId.parse('a|lib/b.txt');
    var bSourceNode = AssetNode.source(bId, digest: computeDigest(bId, 'b'));

    // Regular generated asset nodes.
    var aCopyId = AssetId.parse('a|web/a.txt.copy');
    var aCopyNode = AssetNode.generated(
      aCopyId,
      phaseNumber: 0,
      primaryInput: makeAssetId('a|web/a.txt'),
      result: true,
      digest: computeDigest(aCopyId, 'a'),
      inputs: [makeAssetId('a|web/a.txt')],
      isHidden: false,
    );
    aSourceNode = aSourceNode.rebuild(
      (b) => b..primaryOutputs.add(aCopyNode.id),
    );

    var bCopyId = makeAssetId('a|lib/b.txt.copy'); //;
    var bCopyNode = AssetNode.generated(
      bCopyId,
      phaseNumber: 0,
      primaryInput: makeAssetId('a|lib/b.txt'),
      result: true,
      digest: computeDigest(bCopyId, 'b'),
      inputs: [makeAssetId('a|lib/b.txt')],
      isHidden: false,
    );
    bSourceNode = bSourceNode.rebuild(
      (b) => b..primaryOutputs.add(bCopyNode.id),
    );

    // Post build generates asset nodes.
    var aPostProcessBuildStepId = PostProcessBuildStepId(
      input: aSourceNode.id,
      actionNumber: 0,
    );
    var bPostProcessBuildStepId = PostProcessBuildStepId(
      input: bSourceNode.id,
      actionNumber: 0,
    );

    var aPostCopyNode = AssetNode.generated(
      makeAssetId('a|web/a.txt.post'),
      phaseNumber: 1,
      primaryInput: makeAssetId('a|web/a.txt'),
      result: true,
      digest: computeDigest(makeAssetId(r'$$a|web/a.txt.post'), 'a'),
      inputs: [makeAssetId('a|web/a.txt')],
      isHidden: true,
    );
    // Note we don't expect this node to get added to the builder options node
    // outputs.
    aSourceNode = aSourceNode.rebuild(
      (b) => b..primaryOutputs.add(aPostCopyNode.id),
    );

    var bPostCopyNode = AssetNode.generated(
      makeAssetId('a|lib/b.txt.post'),
      phaseNumber: 1,
      primaryInput: makeAssetId('a|lib/b.txt'),
      result: true,
      digest: computeDigest(makeAssetId(r'$$a|lib/b.txt.post'), 'b'),
      inputs: [makeAssetId('a|lib/b.txt')],
      isHidden: true,
    );
    // Note we don't expect this node to get added to the builder options node
    // outputs.
    bSourceNode = bSourceNode.rebuild(
      (b) => b..primaryOutputs.add(bPostCopyNode.id),
    );

    expectedGraph
      ..add(aSourceNode)
      ..add(bSourceNode)
      ..add(aCopyNode)
      ..add(bCopyNode)
      ..add(aPostCopyNode)
      ..add(bPostCopyNode)
      ..updatePostProcessBuildStep(
        aPostProcessBuildStepId,
        outputs: {aPostCopyNode.id},
      )
      ..updatePostProcessBuildStep(
        bPostProcessBuildStepId,
        outputs: {bPostCopyNode.id},
      );

    expect(cachedGraph, equalsAssetGraph(expectedGraph));
    expect(
      cachedGraph.allPostProcessBuildStepOutputs,
      expectedGraph.allPostProcessBuildStepOutputs,
    );
  });

  test(
    "builders reading their output don't cause self-referential nodes",
    () async {
      final result = await testPhases(
        [
          apply(
            '',
            [
              (_) {
                return TestBuilder(
                  build: (step, _) async {
                    final output = step.inputId.addExtension('.out');
                    await step.writeAsString(output, 'a');
                    await step.readAsString(output);
                  },
                  buildExtensions: appendExtension('.out', from: '.txt'),
                );
              },
            ],
            toRoot(),
            isOptional: false,
            hideOutput: false,
          ),
        ],
        {'a|lib/a.txt': 'a'},
        outputs: {'a|lib/a.txt.out': 'a'},
      );

      final graphId = makeAssetId('a|$assetGraphPath');
      final cachedGraph = AssetGraph.deserialize(
        result.readerWriter.testing.readBytes(graphId),
      );
      final outputId = AssetId('a', 'lib/a.txt.out');

      final outputNode = cachedGraph.get(outputId)!;
      expect(outputNode.generatedNodeState!.inputs, isNot(contains(outputId)));
    },
  );

  test(
    'outputs from previous full builds shouldn\'t be inputs to later ones',
    () async {
      var inputs = <String, String>{'a|web/a.txt': 'a', 'a|lib/b.txt': 'b'};
      var outputs = <String, String>{
        'a|web/a.txt.copy': 'a',
        'a|lib/b.txt.copy': 'b',
      };
      // First run, nothing special.
      final result = await testPhases(
        [copyABuilderApplication],
        inputs,
        outputs: outputs,
      );
      // Second run, should have no outputs.
      await testPhases(
        [copyABuilderApplication],
        inputs,
        outputs: {},
        resumeFrom: result,
      );
    },
  );

  test('can recover from a deleted asset_graph.json cache', () async {
    var inputs = <String, String>{'a|web/a.txt': 'a', 'a|lib/b.txt': 'b'};
    var outputs = <String, String>{
      'a|web/a.txt.copy': 'a',
      'a|lib/b.txt.copy': 'b',
    };
    // First run, nothing special.
    final result = await testPhases(
      [copyABuilderApplication],
      inputs,
      outputs: outputs,
    );

    // Delete the `asset_graph.json` file!
    var outputId = makeAssetId('a|$assetGraphPath');
    await result.readerWriter.delete(outputId);

    // Second run, should have no extra outputs.
    var done = testPhases(
      [copyABuilderApplication],
      inputs,
      outputs: outputs,
      resumeFrom: result,
    );
    // Should block on user input.
    await Future<void>.delayed(const Duration(seconds: 1));
    // Now it should complete!
    await done;
  });

  group('incremental builds with cached graph', () {
    // Using `resumeFrom: result` to pass the filesystem between `testBuilders`
    // calls causes the serialized graph from the previous build to be loaded,
    // exactly as in real builds.

    test('one new asset, one modified asset, one unchanged asset', () async {
      var builders = [copyABuilderApplication];

      // Initial build.
      final result = await testPhases(
        builders,
        {'a|web/a.txt': 'a', 'a|lib/b.txt': 'b'},
        outputs: {'a|web/a.txt.copy': 'a', 'a|lib/b.txt.copy': 'b'},
      );

      // Followup build with modified inputs.
      await testPhases(
        builders,
        {
          'a|web/a.txt': 'a2',
          'a|web/a.txt.copy': 'a',
          'a|lib/b.txt': 'b',
          'a|lib/b.txt.copy': 'b',
          'a|lib/c.txt': 'c',
        },
        outputs: {'a|web/a.txt.copy': 'a2', 'a|lib/c.txt.copy': 'c'},
        resumeFrom: result,
      );
    });

    test(
      'deleting only the second output of a builder causes it to rerun',
      () async {
        var builders = [
          applyToRoot(
            TestBuilder(
              buildExtensions: {
                '.txt': ['.txt.1', '.txt.2'],
              },
            ),
          ),
        ];

        // Initial build.
        final result = await testPhases(
          builders,
          {'a|lib/a.txt': 'a'},
          outputs: {'a|lib/a.txt.1': 'a', 'a|lib/a.txt.2': 'a'},
        );

        // Followup build with the 2nd output missing.
        result.readerWriter.testing.delete(AssetId('a', 'lib/a.txt.2'));
        await testPhases(
          builders,
          {'a|lib/a.txt': 'a', 'a|lib/a.txt.1': 'a'},
          outputs: {'a|lib/a.txt.1': 'a', 'a|lib/a.txt.2': 'a'},
          resumeFrom: result,
        );
      },
    );

    group('reportUnusedAssets', () {
      test('removes input dependencies', () async {
        final builder = TestBuilder(
          buildExtensions: appendExtension('.copy', from: '.txt'),
          // Add two extra deps, but remove one since we decided not to use
          // it.
          build: (BuildStep buildStep, _) async {
            var usedId = buildStep.inputId.addExtension('.used');

            var content =
                await buildStep.readAsString(buildStep.inputId) +
                await buildStep.readAsString(usedId);
            await buildStep.writeAsString(
              buildStep.inputId.addExtension('.copy'),
              content,
            );

            var unusedId = buildStep.inputId.addExtension('.unused');
            await buildStep.canRead(unusedId);
            buildStep.reportUnusedAssets([unusedId]);
          },
        );
        var builders = [applyToRoot(builder)];

        // Initial build.
        final result = await testPhases(
          builders,
          {
            'a|lib/a.txt': 'a',
            'a|lib/a.txt.used': 'b',
            'a|lib/a.txt.unused': 'c',
          },
          outputs: {'a|lib/a.txt.copy': 'ab'},
        );

        // Followup build with modified unused inputs should have no outputs.
        await testPhases(
          builders,
          {
            'a|lib/a.txt': 'a',
            'a|lib/a.txt.used': 'b',
            'a|lib/a.txt.unused': 'd', // changed the content of this one
            'a|lib/a.txt.copy': 'ab',
          },
          outputs: {},
          resumeFrom: result,
        );

        // And now modify a real input.
        await testPhases(
          builders,
          {
            'a|lib/a.txt': 'a',
            'a|lib/a.txt.used': 'e',
            'a|lib/a.txt.unused': 'd',
            'a|lib/a.txt.copy': 'ab',
          },
          outputs: {'a|lib/a.txt.copy': 'ae'},
          resumeFrom: result,
        );

        // Finally modify the primary input.
        await testPhases(
          builders,
          {
            'a|lib/a.txt': 'f',
            'a|lib/a.txt.used': 'e',
            'a|lib/a.txt.unused': 'd',
            'a|lib/a.txt.copy': 'ae',
          },
          outputs: {'a|lib/a.txt.copy': 'fe'},
          resumeFrom: result,
        );
      });

      test('allows marking the primary input as unused', () async {
        final builder = TestBuilder(
          buildExtensions: appendExtension('.copy', from: '.txt'),
          // Add two extra deps, but remove one since we decided not to use
          // it.
          extraWork: (BuildStep buildStep, _) async {
            buildStep.reportUnusedAssets([buildStep.inputId]);
            var usedId = buildStep.inputId.addExtension('.used');
            await buildStep.canRead(usedId);
          },
        );
        var builders = [applyToRoot(builder)];

        // Initial build.
        final result = await testPhases(
          builders,
          {'a|lib/a.txt': 'a', 'a|lib/a.txt.used': ''},
          outputs: {'a|lib/a.txt.copy': 'a'},
        );

        // Followup build with modified primary input should have no outputs.
        await testPhases(
          builders,
          {'a|lib/a.txt': 'b', 'a|lib/a.txt.used': '', 'a|lib/a.txt.copy': 'a'},
          outputs: {},
          resumeFrom: result,
        );

        // But modifying other inputs still causes a rebuild.
        await testPhases(
          builders,
          {
            'a|lib/a.txt': 'b',
            'a|lib/a.txt.used': 'b',
            'a|lib/a.txt.copy': 'a',
          },
          outputs: {'a|lib/a.txt.copy': 'b'},
          resumeFrom: result,
        );
      });

      test(
        'marking the primary input as unused still tracks if it is deleted',
        () async {
          final builder = TestBuilder(
            buildExtensions: appendExtension('.copy', from: '.txt'),
            // Add two extra deps, but remove one since we decided not to use
            // it.
            extraWork: (BuildStep buildStep, _) async {
              buildStep.reportUnusedAssets([buildStep.inputId]);
            },
          );
          var builders = [applyToRoot(builder)];

          // Initial build.
          final result = await testPhases(
            builders,
            {'a|lib/a.txt': 'a'},
            outputs: {'a|lib/a.txt.copy': 'a'},
          );

          // Delete the primary input, the output shoud still be deleted
          result.readerWriter.testing.delete(AssetId('a', 'lib/a.txt'));
          await testPhases(
            builders,
            {'a|lib/a.txt.copy': 'a'},
            outputs: {},
            resumeFrom: result,
          );

          var graph = AssetGraph.deserialize(
            result.readerWriter.testing.readBytes(
              makeAssetId('a|$assetGraphPath'),
            ),
          );
          expect(
            graph.get(makeAssetId('a|lib/a.txt.copy'))!.type,
            NodeType.missingSource,
          );
        },
      );
    });

    test('graph/file system get cleaned up for deleted inputs', () async {
      var builders = [
        copyABuilderApplication,
        applyToRoot(
          TestBuilder(buildExtensions: replaceExtension('.copy', '.clone')),
        ),
      ];

      // Initial build.
      final result = await testPhases(
        builders,
        {'a|lib/a.txt': 'a'},
        outputs: {'a|lib/a.txt.copy': 'a', 'a|lib/a.txt.clone': 'a'},
      );

      // Followup build with deleted input + cached graph.
      result.readerWriter.testing.delete(AssetId('a', 'lib/a.txt'));
      await testPhases(
        builders,
        {'a|lib/a.txt.copy': 'a', 'a|lib/a.txt.clone': 'a'},
        outputs: {},
        resumeFrom: result,
      );

      /// Should be deleted using the writer, and converted to missingSource.
      var newGraph = AssetGraph.deserialize(
        result.readerWriter.testing.readBytes(makeAssetId('a|$assetGraphPath')),
      );
      var aNodeId = makeAssetId('a|lib/a.txt');
      var aCopyNodeId = makeAssetId('a|lib/a.txt.copy');
      var aCloneNodeId = makeAssetId('a|lib/a.txt.copy.clone');
      expect(newGraph.get(aNodeId)!.type, NodeType.missingSource);
      expect(newGraph.get(aCopyNodeId)!.type, NodeType.missingSource);
      expect(newGraph.contains(aCloneNodeId), isFalse);
      expect(result.readerWriter.testing.exists(aNodeId), isFalse);
      expect(result.readerWriter.testing.exists(aCopyNodeId), isFalse);
      expect(result.readerWriter.testing.exists(aCloneNodeId), isFalse);
    });

    test('no outputs if no changed sources', () async {
      var builders = [copyABuilderApplication];

      // Initial build.
      final result = await testPhases(
        builders,
        {'a|web/a.txt': 'a'},
        outputs: {'a|web/a.txt.copy': 'a'},
      );

      // Followup build with same sources + cached graph.
      await testPhases(builders, {}, outputs: {}, resumeFrom: result);
    });

    test('no outputs if no changed sources using `hideOutput: true`', () async {
      var builders = [
        apply('', [(_) => TestBuilder()], toRoot(), hideOutput: true),
      ];

      // Initial build.
      final result = await testPhases(
        builders,
        {'a|web/a.txt': 'a'},
        // Note that `testBuilders` converts generated cache dir paths to the
        // original ones for matching.
        outputs: {r'$$a|web/a.txt.copy': 'a'},
      );

      // Followup build with same sources + cached graph.
      await testPhases(builders, {}, outputs: {}, resumeFrom: result);
    });

    test('inputs/outputs are updated if they change', () async {
      // Initial build.
      final result = await testPhases(
        [
          applyToRoot(
            TestBuilder(
              buildExtensions: appendExtension('.copy', from: '.a'),
              build: copyFrom(makeAssetId('a|lib/file.b')),
            ),
          ),
        ],
        {'a|lib/file.a': 'a', 'a|lib/file.b': 'b', 'a|lib/file.c': 'c'},
        outputs: {'a|lib/file.a.copy': 'b'},
      );

      // Followup build with same sources + cached graph, but configure the
      // builder to read a different file.
      await testPhases(
        [
          applyToRoot(
            TestBuilder(
              buildExtensions: appendExtension('.copy', from: '.a'),
              build: copyFrom(makeAssetId('a|lib/file.c')),
            ),
          ),
        ],
        {
          'a|lib/file.a': 'a',
          'a|lib/file.a.copy': 'b',
          // Hack to get the file to rebuild, we are being bad by changing the
          // builder but pretending its the same.
          'a|lib/file.b': 'b2',
          'a|lib/file.c': 'c',
        },
        outputs: {'a|lib/file.a.copy': 'c'},
        resumeFrom: result,
      );

      // Read cached graph and validate.
      var graph = AssetGraph.deserialize(
        result.readerWriter.testing.readBytes(makeAssetId('a|$assetGraphPath')),
      );
      var outputNode = graph.get(makeAssetId('a|lib/file.a.copy'))!;
      var fileANode = graph.get(makeAssetId('a|lib/file.a'))!;
      var fileBNode = graph.get(makeAssetId('a|lib/file.b'))!;
      var fileCNode = graph.get(makeAssetId('a|lib/file.c'))!;
      expect(
        outputNode.generatedNodeState!.inputs,
        unorderedEquals([fileANode.id, fileCNode.id]),
      );
      final computedOutputs = graph.computeOutputs();
      expect(computedOutputs[fileANode.id]!, contains(outputNode.id));
      expect(computedOutputs[fileBNode.id] ?? const <AssetId>{}, isEmpty);
      expect(computedOutputs[fileCNode.id]!, unorderedEquals([outputNode.id]));
    });

    test('Ouputs aren\'t rebuilt if their inputs didn\'t change', () async {
      var builders = [
        applyToRoot(
          TestBuilder(
            buildExtensions: appendExtension('.copy', from: '.a'),
            build: copyFrom(makeAssetId('a|lib/file.b')),
          ),
        ),
        applyToRoot(
          TestBuilder(
            buildExtensions: appendExtension('.copy', from: '.a.copy'),
          ),
        ),
      ];

      // Initial build.
      final result = await testPhases(
        builders,
        {'a|lib/file.a': 'a', 'a|lib/file.b': 'b'},
        outputs: {'a|lib/file.a.copy': 'b', 'a|lib/file.a.copy.copy': 'b'},
      );

      // Modify the primary input of `file.a.copy`, but its output doesn't
      // change so `file.a.copy.copy` shouldn't be rebuilt.
      await testPhases(
        builders,
        {
          'a|lib/file.a': 'a2',
          'a|lib/file.b': 'b',
          'a|lib/file.a.copy': 'b',
          'a|lib/file.a.copy.copy': 'b',
        },
        outputs: {'a|lib/file.a.copy': 'b'},
        resumeFrom: result,
      );
    });

    test('no implicit dependency on primary input contents', () async {
      var builders = [applyToRoot(SiblingCopyBuilder())];

      // Initial build.
      var result = await testPhases(
        builders,
        {'a|web/a.txt': 'a', 'a|web/a.txt.sibling': 'sibling'},
        outputs: {'a|web/a.txt.new': 'sibling'},
      );

      // Followup build with cached graph and a changed primary input, but the
      // actual file that was read has not changed.
      result = await testPhases(
        builders,
        {
          'a|web/a.txt': 'b',
          'a|web/a.txt.sibling': 'sibling',
          'a|web/a.txt.new': 'sibling',
        },
        outputs: {},
        resumeFrom: result,
      );

      // And now try modifying the sibling to make sure that still works.
      await testPhases(
        builders,
        {
          'a|web/a.txt': 'b',
          'a|web/a.txt.sibling': 'new!',
          'a|web/a.txt.new': 'sibling',
        },
        outputs: {'a|web/a.txt.new': 'new!'},
        resumeFrom: result,
      );
    });
  });

  group('regression tests', () {
    test('a failed output on a primary input which is not output in later '
        'builds', () async {
      var builders = [
        applyToRoot(
          TestBuilder(
            buildExtensions: replaceExtension('.source', '.g1'),
            build: (buildStep, _) async {
              var content = await buildStep.readAsString(buildStep.inputId);
              if (content == 'true') {
                await buildStep.writeAsString(
                  buildStep.inputId.changeExtension('.g1'),
                  '',
                );
              }
            },
          ),
        ),
        applyToRoot(
          TestBuilder(
            buildExtensions: replaceExtension('.g1', '.g2'),
            build: (buildStep, _) {
              throw StateError('Fails always');
            },
          ),
        ),
      ];
      final result = await testPhases(builders, {
        'a|lib/a.source': 'true',
      }, status: BuildStatus.failure);

      await testPhases(
        builders,
        {'a|lib/a.source': 'false'},
        outputs: {},
        resumeFrom: result,
      );
    });

    test('the entrypoint cannot be read by a builder', () async {
      var builders = [
        applyToRoot(
          TestBuilder(
            buildExtensions: replaceExtension('.txt', '.hasEntrypoint'),
            build: (buildStep, _) async {
              var hasEntrypoint = await buildStep
                  .findAssets(Glob('**'))
                  .contains(
                    makeAssetId('a|.dart_tool/build/entrypoint/build.dart'),
                  );
              await buildStep.writeAsString(
                buildStep.inputId.changeExtension('.hasEntrypoint'),
                '$hasEntrypoint',
              );
            },
          ),
        ),
      ];
      await testPhases(
        builders,
        {
          'a|lib/a.txt': 'a',
          'a|.dart_tool/build/entrypoint/build.dart': 'some build script',
        },
        outputs: {'a|lib/a.hasEntrypoint': 'false'},
      );
    });

    test('primary outputs are reran when failures are fixed', () async {
      var builders = [
        applyToRoot(
          TestBuilder(
            buildExtensions: replaceExtension('.source', '.g1'),
            build: (buildStep, _) async {
              var content = await buildStep.readAsString(buildStep.inputId);
              if (content == 'true') {
                throw StateError('Failed!!!');
              } else {
                await buildStep.writeAsString(
                  buildStep.inputId.changeExtension('.g1'),
                  '',
                );
              }
            },
          ),
          isOptional: true,
        ),
        applyToRoot(
          TestBuilder(
            buildExtensions: replaceExtension('.g1', '.g2'),
            build: (buildStep, _) async {
              await buildStep.writeAsString(
                buildStep.inputId.changeExtension('.g2'),
                '',
              );
            },
          ),
          isOptional: true,
        ),
        applyToRoot(
          TestBuilder(
            buildExtensions: replaceExtension('.g2', '.g3'),
            build: (buildStep, _) async {
              await buildStep.writeAsString(
                buildStep.inputId.changeExtension('.g3'),
                '',
              );
            },
          ),
        ),
      ];
      var result = await testPhases(builders, {
        'a|web/a.source': 'true',
      }, status: BuildStatus.failure);

      result = await testPhases(
        builders,
        {'a|web/a.source': 'false'},
        outputs: {'a|web/a.g1': '', 'a|web/a.g2': '', 'a|web/a.g3': ''},
        resumeFrom: result,
      );

      // Make sure if we mark the original node as a failure again, that we
      // also mark all its primary outputs as failures.
      await testPhases(
        builders,
        {'a|web/a.source': 'true'},
        outputs: {},
        status: BuildStatus.failure,
        resumeFrom: result,
      );

      var finalGraph = AssetGraph.deserialize(
        result.readerWriter.testing.readBytes(AssetId('a', assetGraphPath)),
      );

      expect(
        finalGraph.get(AssetId('a', 'web/a.g1'))!.generatedNodeState!.result,
        isFalse,
      );
      expect(
        finalGraph.get(AssetId('a', 'web/a.g2'))!.generatedNodeState!.result,
        isFalse,
      );
      expect(
        finalGraph.get(AssetId('a', 'web/a.g3'))!.generatedNodeState!.result,
        isFalse,
      );
    });

    test('a glob should not be an output of an anchor node', () async {
      // https://github.com/dart-lang/build/issues/2017
      var builders = [
        apply(
          'test_builder',
          [
            (_) => TestBuilder(
              build: (buildStep, _) {
                buildStep.findAssets(Glob('**'));
              },
            ),
          ],
          toRoot(),
          appliesBuilders: ['a|copy_builder'],
        ),
        applyPostProcess('a|copy_builder', (_) => CopyingPostProcessBuilder()),
      ];
      // A build does not crash in `_cleanUpStaleOutputs`
      await testPhases(builders, {'a|lib/a.txt': 'a'});
    });

    test('can have assets ending in a dot', () async {
      var builders = [
        applyToRoot(
          TestBuilder(
            buildExtensions: {
              '': ['copy'],
            },
            build: (step, _) async {
              await step.writeAsString(step.allowedOutputs.single, 'out');
            },
          ),
        ),
      ];
      await testPhases(
        builders,
        {'a|lib/a.': 'a'},
        outputs: {'a|lib/a.copy': 'out'},
      );
    });
  });
}

/// A builder that never actually reads its primary input, but copies from a
/// sibling file instead.
class SiblingCopyBuilder extends Builder {
  @override
  final buildExtensions = {
    '.txt': ['.txt.new'],
  };

  @override
  Future build(BuildStep buildStep) async {
    var sibling = buildStep.inputId.addExtension('.sibling');
    await buildStep.writeAsString(
      buildStep.inputId.addExtension('.new'),
      await buildStep.readAsString(sibling),
    );
  }
}
