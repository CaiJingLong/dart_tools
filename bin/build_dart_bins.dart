import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

String pubHost = 'https://pub.dev';

Future<Directory> downloadPkg(String pkgName) async {
  // 1. Use pub.dev api to get the package info
  final url = '$pubHost/api/packages/$pkgName';
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) {
    throw Exception('Failed to get package info');
  }

  // 2. Get the package info
  final pkgInfo = response.body;

  final map = json.decode(pkgInfo) as Map<String, dynamic>;
  final latest = map['latest'] as Map<String, dynamic>;
  final version = latest['version'] as String;
  final tarUrl = latest['archive_url'] as String;

  // 3. Download the package
  final pkgDir = Directory('tmp/$pkgName');
  if (!pkgDir.existsSync()) {
    pkgDir.createSync(recursive: true);
  }

  final tarFile = File('tmp/$pkgName/$version.tar.gz');
  if (!tarFile.existsSync()) {
    final response = await http.get(Uri.parse(tarUrl));
    if (response.statusCode != 200) {
      throw Exception('Failed to download package');
    }
    tarFile.writeAsBytesSync(response.bodyBytes);
  }

  // 4. Unzip the package
  final unzipDir = Directory('tmp/$pkgName/$version');
  if (!unzipDir.existsSync()) {
    unzipDir.createSync(recursive: true);
  }

  final process = await Process.start(
    'tar',
    ['-xzf', tarFile.path, '-C', unzipDir.path],
  );

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    throw Exception('Failed to unzip package');
  }

  return unzipDir;
}

/// Get with pub package, and build all bins
Future<void> main(List<String> arguments) async {
  if (Platform.environment['PUB_HOSTED_URL'] != null) {
    pubHost = Platform.environment['PUB_HOSTED_URL']!;
  }

  /// 1. Get with pub package
  final pkgNames = arguments;

  /// 2. Get with pub package
  for (final pkgName in pkgNames) {
    final sourceDir = await downloadPkg(pkgName);
    final version = sourceDir.path.split('/').last;

    // 3. Build the bin
    final bins = Directory('${sourceDir.path}/bin');
    final targetPath = Directory('output/$pkgName/$version').absolute.path;
    print('The target dir path is: $targetPath');
    if (bins.existsSync()) {
      final files = bins
          .listSync()
          .whereType<File>()
          .where((element) => element.path.endsWith('.dart'));
      for (final file in files) {
        try {
          final basename = file.path.split('/').last;
          final binName = basename.split('.').first;
          final binPath = '$targetPath/$binName';

          if (File(binPath).existsSync()) {
            print('The bin is already built: $binPath');
            continue;
          } else {
            File(binPath).parent.createSync(recursive: true);
          }

          await fakeDir(sourceDir, () async {
            final pubGetCommand = 'dart pub get';
            final pubGetProcess = await Process.start(
              'bash',
              ['-c', pubGetCommand],
              workingDirectory: sourceDir.path,
            );
            if (await pubGetProcess.exitCode != 0) {
              throw Exception('Failed to run pub get for $pkgName');
            }
            print(
                'Build command: dart compile exe ${file.absolute.path} -o $binPath');
            final process = await Process.start(
              'dart',
              ['compile', 'exe', file.absolute.path, '-o', binPath],
              workingDirectory: sourceDir.path,
            );

            final exitCode = await process.exitCode;
            if (exitCode != 0) {
              final error = await process.stderr.transform(utf8.decoder).join();
              print(error);
              throw Exception('Failed to build bin');
            }

            print('The bin is built: $binPath');
          });
        } catch (e) {
          print('Failed to build bin for $pkgName');
          print(e);
        }
      }
    }
  }
}

Future<void> fakeDir(
    Directory sourceDir, Future<void> Function() runMethod) async {
  // Some packages need get the dev_dependency with relative path
  // so we need change pubspec.yaml to do it

  final srcPubspec = File('${sourceDir.path}/pubspec.yaml');
  final srcText = await srcPubspec.readAsString();
  try {
    // find the dev_dependency and change it
    final lines = srcText.split('\n');
    final devDepIndex =
        lines.indexWhere((element) => element.contains('dev_dependencies:'));
    if (devDepIndex == -1) {
      runMethod();
      return;
    }
    var endIndex = -1;

    for (var index = devDepIndex + 1; index < lines.length; index++) {
      final line = lines[index];
      if (line.trim().isEmpty && !line.trim().startsWith('#')) {
        endIndex = index;
        break;
      }
    }

    if (endIndex == -1) {
      endIndex = lines.length;
      return;
    }

    final newTextSb = StringBuffer();
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (index >= devDepIndex && index < endIndex) {
        if (line.trim().startsWith('#')) {
          newTextSb.writeln(line);
        } else {
          newTextSb.writeln('# $line');
        }
      } else {
        newTextSb.writeln(line);
      }
    }

    await srcPubspec.writeAsString(newTextSb.toString());

    await runMethod();

    // restore the pubspec.yaml
  } catch (e) {
    await srcPubspec.writeAsString(srcText);
  }
}
