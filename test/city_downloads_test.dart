import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:city_runner/src/city_downloads.dart';
import 'package:city_runner/src/city_runner_screen.dart';

class _SocketHttpOverrides extends HttpOverrides {}

void main() {
  late HttpServer server;
  late Directory directory;
  late CityDownloads store;
  late Uri manifest;
  final requests = <String>[];
  var corrupt = false;
  var fail = false;
  Completer<void>? release;
  const commonHash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const rohtakHash =
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const hisarHash =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
  const payloads = {
    commonHash: 'common',
    rohtakHash: 'rohtak',
    hisarHash: 'hisar',
  };
  Map<String, Object> descriptor(String name, String hash) => {
    'url': '$name.pck',
    'bytes': payloads[hash]!.length,
    'sha256': hash,
  };

  setUp(() async {
    HttpOverrides.global = _SocketHttpOverrides();
    requests.clear();
    corrupt = false;
    fail = false;
    release = null;
    directory = await Directory.systemTemp.createTemp('cityrunner-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    manifest = Uri.parse('http://127.0.0.1:${server.port}/manifest.json');
    server.listen((request) async {
      requests.add(request.uri.path);
      try {
        if (request.uri.path == '/manifest.json') {
          request.response.write(
            jsonEncode({
              'schema': 1,
              'platform': 'android',
              'engine': '4.6.0.stable',
              'common': [descriptor('common', commonHash)],
              'cities': [
                for (final name in ['rohtak', 'hisar'])
                  {
                    'id': name,
                    'name': name,
                    'nameLocal': name,
                    'state': 'Haryana',
                    'files': [
                      descriptor(
                        name,
                        name == 'rohtak' ? rohtakHash : hisarHash,
                      ),
                    ],
                  },
              ],
            }),
          );
        } else if (fail) {
          request.response.statusCode = HttpStatus.serviceUnavailable;
        } else {
          final name = request.uri.path.substring(1).split('.').first;
          if (name == 'rohtak' && release != null) {
            request.response.bufferOutput = false;
            request.response.contentLength = 6;
            request.response.write('r');
            await request.response.flush();
            await release!.future;
            request.response.write('ohtak');
          } else {
            request.response.write(corrupt ? 'broken' : name);
          }
        }
        await request.response.close();
      } catch (_) {
        /* A cancelled client closes the response socket. */
      }
    });
    store = CityDownloads(
      directory,
      (file, pack) async => await file.readAsString() == payloads[pack.sha256],
    );
    await store.load(manifest);
  });

  tearDown(() async {
    store.dispose();
    if (release != null && !release!.isCompleted) release!.complete();
    await server.close(force: true);
    await directory.delete(recursive: true);
    HttpOverrides.global = null;
  });

  test(
    'catalogue fetch downloads no art; Rohtak fetches only common and Rohtak',
    () async {
      expect(requests, ['/manifest.json']);
      expect(await store.downloadBytes(store.cities.first), 12);
      await store.install(store.cities.first, (_, _) {});
      expect(requests, ['/manifest.json', '/common.pck', '/rohtak.pck']);
      expect(await store.downloadBytes(store.cities.first), 0);
      requests.clear();
      await store.install(store.cities.first, (_, _) {});
      expect(requests, isEmpty);
    },
  );

  test(
    'integrity failure leaves no installed city and retry succeeds',
    () async {
      corrupt = true;
      await expectLater(
        store.install(store.cities.first, (_, _) {}),
        throwsFormatException,
      );
      expect(await directory.list().toList(), isEmpty);
      corrupt = false;
      await store.install(store.cities.first, (_, _) {});
      expect(await store.downloadBytes(store.cities.first), 0);
    },
  );

  test(
    'cancel removes partial city, preserves verified common and permits retry',
    () async {
      release = Completer<void>();
      var cancelled = false;
      final install = store.install(store.cities.first, (received, _) {
        if (received > 6 && !cancelled) {
          cancelled = true;
          store.cancel();
        }
      });
      await expectLater(install, throwsA(isA<DownloadCancelled>()));
      expect(await directory.list().map((file) => file.path).toList(), [
        store.fileFor(store.common.first).path,
      ]);
      release!.complete();
      release = null;
      await store.install(store.cities.first, (_, _) {});
      expect(await store.downloadBytes(store.cities.first), 0);
    },
  );

  test('city removal preserves common and another installed city', () async {
    await store.install(store.cities.first, (_, _) {});
    await store.install(store.cities.last, (_, _) {});
    await store.remove(store.cities.first);
    expect(
      await store.fileFor(store.cities.first.files.first).exists(),
      isFalse,
    );
    expect(await store.downloadBytes(store.cities.last), 0);
  });

  test('corrupted saved content is verified again before play', () async {
    await store.install(store.cities.first, (_, _) {});
    await store.fileFor(store.cities.first.files.first).writeAsString('broken');
    requests.clear();
    await store.install(store.cities.first, (_, _) {});
    expect(requests, ['/rohtak.pck']);
    expect(
      await store.fileFor(store.cities.first.files.first).readAsString(),
      'rohtak',
    );
  });

  test('HTTP failure remains retryable', () async {
    fail = true;
    await expectLater(
      store.install(store.cities.first, (_, _) {}),
      throwsA(isA<HttpException>()),
    );
    fail = false;
    await store.install(store.cities.first, (_, _) {});
    expect(await store.downloadBytes(store.cities.first), 0);
  });

  testWidgets('native view handles Back and can close and open again', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final launches = <Completer<void>>[];
    var backs = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') return 1;
      if (call.method == 'resize') {
        final args = call.arguments as Map;
        return {'width': args['width'], 'height': args['height']};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(NativeRunner.channel, (call) async {
      switch (call.method) {
        case 'cacheRoot':
          return directory.path;
        case 'verify':
          final args = call.arguments as Map;
          return await File(args['path'] as String).readAsString() ==
              payloads[args['sha256']];
        case 'launch':
          final completion = Completer<void>();
          launches.add(completion);
          await completion.future;
          return null;
        case 'back':
          backs++;
          return null;
      }
      throw StateError('Unexpected native method');
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      messenger.setMockMethodCallHandler(NativeRunner.channel, null);
    });
    Future<void> waitUntil(bool Function() ready) async {
      for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
      expect(ready(), isTrue);
    }

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: CityRunnerScreen(manifest: manifest, onExit: () {})),
      );
      await waitUntil(() => find.text('rohtak').evaluate().isNotEmpty);
      await tester.tap(find.text('rohtak'));
      await waitUntil(
        () => tester
            .widgetList<FilledButton>(find.byType(FilledButton))
            .any((button) => button.onPressed != null),
      );
      for (var run = 0; run < 2; run++) {
        await tester.tap(find.text(run == 0 ? 'Download & play' : 'Play city'));
        await waitUntil(() => launches.length == run + 1);
        await tester.pump();
        expect(find.byType(AndroidView), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(backs, run + 1);
        expect(find.byType(AndroidView), findsOneWidget);
        launches[run].complete();
        await waitUntil(() => find.text('Play city').evaluate().isNotEmpty);
        expect(find.byType(AndroidView), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
    expect(tester.takeException(), isNull);
  });

  for (final action in ['cancel', 'background', 'unmount']) {
    testWidgets('$action during audio handoff prevents native launch', (
      tester,
    ) async {
      final entered = Completer<void>();
      final handoff = Completer<void>();
      var launches = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeRunner.channel, (call) async {
        switch (call.method) {
          case 'cacheRoot':
            return directory.path;
          case 'verify':
            final arguments = call.arguments as Map;
            return await File(arguments['path'] as String).readAsString() ==
                payloads[arguments['sha256']];
          case 'launch':
            launches++;
            return null;
        }
        throw StateError('Unexpected native method');
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(NativeRunner.channel, null);
      });

      Future<void> waitUntil(bool Function() ready) async {
        for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
        expect(ready(), isTrue);
      }

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: CityRunnerScreen(
              manifest: manifest,
              onExit: () {},
              beforeNativeLaunch: () {
                entered.complete();
                return handoff.future;
              },
            ),
          ),
        );
        await waitUntil(() => find.text('rohtak').evaluate().isNotEmpty);
        await tester.tap(find.text('rohtak'));
        await waitUntil(() {
          final buttons = tester.widgetList<FilledButton>(
            find.byType(FilledButton),
          );
          return buttons.isNotEmpty && buttons.single.onPressed != null;
        });
        await tester.tap(find.text('Download & play'));
        await waitUntil(() => entered.isCompleted);
        await tester.pump();
        if (action == 'cancel') {
          await tester.tap(find.text('Cancel'));
        } else if (action == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        } else {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        handoff.complete();
        if (action == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        if (action != 'unmount') {
          await waitUntil(() => find.text('Cancel').evaluate().isEmpty);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await tester.pump();
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        expect(launches, 0);
      });
      expect(tester.takeException(), isNull);
    });
  }
}
