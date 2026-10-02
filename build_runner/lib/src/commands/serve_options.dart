// Copyright (c) 2025, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:built_collection/built_collection.dart';
import 'package:path/path.dart' as p;

import '../build_runner_command_line.dart';

class ServeOptions {
  /// Custom response headers, keyed by lowercase HTTP field name.
  final Map<String, String> headers;
  final String hostname;
  final bool liveReload;
  final bool logRequests;
  final BuiltList<ServeTarget> serveTargets;

  ServeOptions({
    this.headers = const {},
    required this.hostname,
    required this.liveReload,
    required this.logRequests,
    required this.serveTargets,
  });

  /// The single host that requests must be addressed to, or `null` if the
  /// server listens on all interfaces so there is no such host.
  ///
  /// `HttpMultiServer.bind` takes `any` as an alias for the wildcard address.
  String? get allowedHost {
    if (hostname == 'any') return null;
    final address = InternetAddress.tryParse(hostname);
    if (address == InternetAddress.anyIPv4 ||
        address == InternetAddress.anyIPv6) {
      return null;
    }
    return hostname;
  }

  static ServeOptions parse(BuildRunnerCommandLine commandLine) {
    final headers = <String, String>{};
    for (final header in commandLine.headers!) {
      final colon = header.indexOf(':');
      final name = colon < 0 ? '' : header.substring(0, colon);
      final value = colon < 0 ? '' : header.substring(colon + 1);
      if (_headerName.firstMatch(name)?.end != name.length ||
          _headerValue.firstMatch(value)?.end != value.length) {
        throw UsageException(
          'Invalid --header: expected a valid HTTP header in "Name: value" '
          'format without control characters.',
          commandLine.usage,
        );
      }
      headers[name.toLowerCase()] = value.trim();
    }

    final serveTargets = <ServeTarget>[];
    var nextDefaultPort = 8080;
    for (final arg in commandLine.rest) {
      final parts = arg.split(':');
      if (parts.length > 2) {
        throw UsageException(
          'Invalid format for positional argument to serve `$arg`'
          ', expected <directory>:<port>.',
          commandLine.usage,
        );
      }

      final port = parts.length == 2
          ? int.tryParse(parts[1])
          : nextDefaultPort++;
      if (port == null) {
        throw UsageException(
          'Unable to parse port number in `$arg`',
          commandLine.usage,
        );
      }

      final path = parts.first;
      final pathParts = p.split(path);
      if (pathParts.length > 1 || path == '.') {
        throw UsageException(
          'Only top level directories such as `web` or `test` are allowed as '
          'positional args, but got `$path`',
          commandLine.usage,
        );
      }

      serveTargets.add(ServeTarget(path, port));
    }
    if (serveTargets.isEmpty) {
      for (final dir in _defaultWebDirs) {
        if (Directory(dir).existsSync()) {
          serveTargets.add(ServeTarget(dir, nextDefaultPort++));
        }
      }
    }

    return ServeOptions(
      headers: Map.unmodifiable(headers),
      hostname: commandLine.hostname!,
      liveReload: commandLine.liveReload!,
      logRequests: commandLine.logRequests!,
      serveTargets: serveTargets.build(),
    );
  }
}

/// A target to serve, representing a directory and a port.
class ServeTarget {
  final String dir;
  final int port;

  ServeTarget(this.dir, this.port);
}

final _defaultWebDirs = const ['web', 'test', 'example', 'benchmark'];

// HTTP field names are tokens; values allow HTAB, visible bytes and obs-text.
final _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
final _headerValue = RegExp(r'^[\t\x20-\x7e\x80-\xff]*$');
