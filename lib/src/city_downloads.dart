import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class NativeRunner {
  static const channel = MethodChannel('in.stage.cityrunner');

  Future<Directory> cacheRoot() async =>
      Directory((await channel.invokeMethod<String>('cacheRoot'))!);

  Future<bool> verify(File file, PackFile pack) async =>
      await channel.invokeMethod<bool>('verify', {
        'path': file.path,
        'bytes': pack.bytes,
        'sha256': pack.sha256,
      }) ??
      false;

  Future<void> back() => channel.invokeMethod<void>('back');
  Future<void> close() => channel.invokeMethod<void>('close');
  Future<bool> engineInstalled() async =>
      await channel.invokeMethod<bool>('engineInstalled') ?? false;
  Future<void> installEngine() async {
    try {
      await channel.invokeMethod<void>('installEngine');
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') throw DownloadCancelled();
      rethrow;
    }
  }

  Future<void> cancelEngine() => channel.invokeMethod<void>('cancelEngine');

  Future<void> launch(String city, List<File> files) =>
      channel.invokeMethod<void>('launch', {
        'city': city,
        'common': files.first.path,
        'packs': files.skip(1).map((file) => file.path).toList(),
      });
}

class PackFile {
  PackFile(Map<String, dynamic> json, Uri manifest)
    : url = manifest.resolve(json['url'] as String),
      bytes = json['bytes'] as int,
      sha256 = json['sha256'] as String {
    if (bytes <= 0 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        url.origin != manifest.origin) {
      throw const FormatException('Invalid city download descriptor');
    }
  }

  final Uri url;
  final int bytes;
  final String sha256;
}

class RunnerCity {
  RunnerCity(Map<String, dynamic> json, Uri manifest)
    : id = json['id'] as String,
      name = json['name'] as String,
      localName = json['nameLocal'] as String,
      state = json['state'] as String,
      files = (json['files'] as List)
          .map((item) => PackFile(item as Map<String, dynamic>, manifest))
          .toList();

  final String id, name, localName, state;
  final List<PackFile> files;
}

class DownloadCancelled implements Exception {}

class CityDownloads {
  CityDownloads(this.root, this.verify);

  final Directory root;
  final Future<bool> Function(File file, PackFile pack) verify;
  List<PackFile> common = [];
  List<RunnerCity> cities = [];
  HttpClient _client = HttpClient();
  int _generation = 0;
  void Function()? _cancelTransfer;

  static const playable = {
    'jaipur',
    'delhi-urban-cluster',
    'mumbai',
    'bengaluru',
    'chennai',
    'kolkata',
    'indore',
    'varanasi',
    'gurugram',
    'hisar',
    'karnal',
    'rohtak',
    'kurukshetra',
    'panipat',
    'sonipat',
  };

  Future<void> load(Uri uri) async {
    if (!['http', 'https'].contains(uri.scheme)) {
      throw const FormatException('A city catalogue URL is required');
    }
    final response = await (await _client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('Catalogue returned HTTP ${response.statusCode}');
    }
    final json =
        jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
    if (json['schema'] != 1 ||
        json['platform'] != 'android' ||
        json['engine'] != '4.6.0.stable') {
      throw const FormatException(
        'This catalogue does not match the native engine',
      );
    }
    final parsed = (json['cities'] as List)
        .map((item) => RunnerCity(item as Map<String, dynamic>, uri))
        .toList();
    if (parsed.any((city) => !playable.contains(city.id)) ||
        parsed.map((city) => city.id).toSet().length != parsed.length) {
      throw const FormatException('Catalogue contains an unavailable city');
    }
    common = (json['common'] as List)
        .map((item) => PackFile(item as Map<String, dynamic>, uri))
        .toList();
    if (common.length != 1) {
      throw const FormatException('One native common pack is required');
    }
    cities = parsed;
    await root.create(recursive: true);
  }

  File fileFor(PackFile pack) => File('${root.path}/${pack.sha256}.pck');
  List<PackFile> filesFor(RunnerCity city) => [...common, ...city.files];

  Future<int> downloadBytes(RunnerCity city) async {
    var total = 0;
    for (final pack in filesFor(city)) {
      final file = fileFor(pack);
      if (!await file.exists() ||
          await file.length() != pack.bytes ||
          !await verify(file, pack)) {
        total += pack.bytes;
      }
    }
    return total;
  }

  Future<List<File>> install(
    RunnerCity city,
    void Function(int received, int total) progress,
  ) async {
    final cancelled = Completer<void>();
    _cancelTransfer = () {
      if (!cancelled.isCompleted) cancelled.complete();
    };
    try {
      return await _install(city, progress, cancelled.future);
    } finally {
      _cancelTransfer = null;
    }
  }

  Future<List<File>> _install(
    RunnerCity city,
    void Function(int received, int total) progress,
    Future<void> cancelled,
  ) async {
    final generation = _generation;
    var received = 0;
    final total = filesFor(city).fold(0, (sum, pack) => sum + pack.bytes);
    for (final pack in filesFor(city)) {
      if (generation != _generation) throw DownloadCancelled();
      final file = fileFor(pack);
      if (await file.exists() && await verify(file, pack)) {
        received += pack.bytes;
        progress(received, total);
        continue;
      }
      if (await file.exists()) await file.delete();
      final partial = File('${file.path}.part');
      IOSink? sink;
      try {
        final response = await Future.any<HttpClientResponse>([
          _client.getUrl(pack.url).then((request) => request.close()),
          cancelled.then((_) => throw DownloadCancelled()),
        ]);
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('Download returned HTTP ${response.statusCode}');
        }
        sink = partial.openWrite();
        var count = 0;
        final transfer = Completer<void>();
        final subscription = response.listen(
          (chunk) {
            if (transfer.isCompleted) return;
            count += chunk.length;
            if (count > pack.bytes) {
              transfer.completeError(
                const FormatException('Download size mismatch'),
              );
              return;
            }
            sink!.add(chunk);
            progress(received + count, total);
          },
          onError: (Object error) {
            if (!transfer.isCompleted) transfer.completeError(error);
          },
          onDone: () {
            if (!transfer.isCompleted) transfer.complete();
          },
        );
        try {
          await Future.any<void>([
            transfer.future,
            cancelled.then((_) => throw DownloadCancelled()),
          ]);
        } finally {
          unawaited(subscription.cancel());
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (generation != _generation) throw DownloadCancelled();
        if (count != pack.bytes || !await verify(partial, pack)) {
          throw const FormatException(
            'Download integrity check failed. Retry the city.',
          );
        }
        await partial.rename(file.path);
        received += pack.bytes;
        progress(received, total);
      } catch (_) {
        if (generation != _generation) throw DownloadCancelled();
        rethrow;
      } finally {
        try {
          await sink?.close();
        } finally {
          if (await partial.exists()) await partial.delete();
        }
      }
    }
    if (generation != _generation) throw DownloadCancelled();
    final valid = {
      ...common,
      ...cities.expand((city) => city.files),
    }.map((pack) => fileFor(pack).path).toSet();
    await for (final entity in root.list()) {
      if (entity is File &&
          entity.path.endsWith('.pck') &&
          !valid.contains(entity.path)) {
        await entity.delete();
      }
    }
    if (generation != _generation) throw DownloadCancelled();
    return filesFor(city).map(fileFor).toList();
  }

  void cancel() {
    _generation++;
    _cancelTransfer?.call();
    _client.close(force: true);
    _client = HttpClient();
  }

  Future<void> remove(RunnerCity city) async {
    final keep = {
      ...common,
      ...cities
          .where((other) => other.id != city.id)
          .expand((other) => other.files),
    }.map((pack) => pack.sha256).toSet();
    for (final pack in city.files) {
      final file = fileFor(pack);
      if (!keep.contains(pack.sha256) && await file.exists()) {
        await file.delete();
      }
    }
  }

  void dispose() {
    _generation++;
    _cancelTransfer?.call();
    _client.close(force: true);
  }
}
