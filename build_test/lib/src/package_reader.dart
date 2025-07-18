// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as p;
import 'package:stream_transform/stream_transform.dart';

/// Resolves using a [PackageConfig] before reading from the file system.
///
/// For a simple implementation that uses the current isolate's package
/// resolution logic (i.e. whatever you have generated in
/// `.dart_tool/package_config.json` in most cases), use [currentIsolate]:
/// ```dart
/// var assetReader = await PackageAssetReader.currentIsolate();
/// ```
///
/// Doesn't implement [AssetReader]: for cases that need an [AssetReader],
/// use this class to read the files then write them into a `TestReaderWriter`.
/// To copy all the sources see `TestReaderWriter.testing.loadIsolateSources`.
class PackageAssetReader {
  /// The package config.
  final PackageConfig packageConfig;

  /// What package is the originating build occurring in.
  final String? _rootPackage;

  /// Wrap a [PackageConfig] to identify where files are located.
  ///
  /// To use a normal [PackageConfig] use `Isolate.packageConfig` and
  /// `loadPackageConfigUri`:
  ///
  /// ```
  /// new PackageAssetReader(
  ///   await loadPackageConfigUri(await Isolate.packageConfig));
  /// ```
  PackageAssetReader(this.packageConfig, [this._rootPackage]);

  /// A [PackageAssetReader] with a single [packageRoot] configured.
  ///
  /// It is assumed that every _directory_ in [packageRoot] is a package where
  /// the name of the package is the name of the directory. This is similar to
  /// the older "packages" folder paradigm for resolution.
  factory PackageAssetReader.forPackageRoot(
    String packageRoot, [
    String? rootPackage,
  ]) {
    final directory = Directory(packageRoot);
    final packages = <String, String>{};
    for (final entity in directory.listSync()) {
      if (entity is Directory) {
        final name = p.basename(entity.path);
        packages[name] = entity.uri.toFilePath(windows: false);
      }
    }
    return PackageAssetReader.forPackages(packages, rootPackage);
  }

  /// Returns a [PackageAssetReader] with a simple [packageToPath] mapping.
  PackageAssetReader.forPackages(
    Map<String, String> packageToPath, [
    String? rootPackage,
  ]) : this(
         PackageConfig([
           for (var entry in packageToPath.entries)
             Package(
               entry.key,
               Uri.file(p.absolute(entry.value)),
               // TODO: use a relative uri when/if possible,
               // https://github.com/dart-lang/package_config/issues/81
               packageUriRoot: Uri.file(p.absolute(entry.value, 'lib/')),
             ),
         ]),
         rootPackage,
       );

  /// A reader that can resolve files known to the current isolate.
  ///
  /// A [rootPackage] should be provided for full API compatibility.
  static Future<PackageAssetReader> currentIsolate({
    String? rootPackage,
  }) async {
    final packageConfigUri =
        await Isolate.packageConfig ??
        (throw UnsupportedError('No package config found'));
    final packageConfig = await loadPackageConfigUri(packageConfigUri);

    return PackageAssetReader(packageConfig, rootPackage);
  }

  File? _resolve(AssetId id) {
    final uri = id.uri;
    if (uri.isScheme('package')) {
      final uri = packageConfig.resolve(id.uri);
      if (uri != null) {
        return File.fromUri(uri);
      }
    }
    if (id.package == _rootPackage) {
      return File(p.canonicalize(p.join(_rootPackagePath, id.path)));
    }
    return null;
  }

  String get _rootPackagePath {
    // If the root package has a pub layout, use `packagePath`.
    final rootPackage = _rootPackage;
    final root =
        rootPackage != null
            ? packageConfig[rootPackage]?.root.toFilePath()
            : null;
    if (root != null && Directory(p.join(root, 'lib')).existsSync()) {
      return root;
    }
    // Assume the cwd is the package root.
    return p.current;
  }

  Stream<AssetId> findAssets(Glob glob, {String? package}) {
    package ??= _rootPackage;
    if (package == null) {
      throw UnsupportedError(
        'Root package must be provided to use `findAssets` without an '
        'explicit `package`.',
      );
    }
    var packageLibDir = packageConfig[package]?.packageUriRoot;
    if (packageLibDir == null) return const Stream.empty();
    var result = const Stream<String>.empty();
    final directory = Directory.fromUri(packageLibDir);
    if (directory.existsSync()) {
      result = result.merge(
        Directory.fromUri(packageLibDir)
            .list(recursive: true)
            .whereType<File>()
            .map(
              (f) => p.join(
                'lib',
                p.relative(f.path, from: p.fromUri(packageLibDir)),
              ),
            ),
      );
    }
    if (package == _rootPackage) {
      result = result.merge(
        Directory(_rootPackagePath)
            .list(recursive: true)
            .whereType<File>()
            .map((f) => p.relative(f.path, from: _rootPackagePath))
            .where((p) => !(p.startsWith('packages/') || p.startsWith('lib/'))),
      );
    }
    return result.where(glob.matches).map((p) => AssetId(package!, p));
  }

  Future<bool> canRead(AssetId id) =>
      _resolve(id)?.exists() ?? Future.value(false);

  Future<List<int>> readAsBytes(AssetId id) =>
      _resolve(id)?.readAsBytes() ?? (throw AssetNotFoundException(id));

  Future<String> readAsString(AssetId id, {Encoding encoding = utf8}) =>
      _resolve(id)?.readAsString(encoding: encoding) ??
      (throw AssetNotFoundException(id));
}
