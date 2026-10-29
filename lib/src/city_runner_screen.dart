import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'city_downloads.dart';

abstract class RunnerTheme {
  static const background = Color(0xff241a2c);
  static const surface = Color(0xff462538);
  static const cream = Color(0xfffff3da);
  static const ink = Color(0xff3b2130);
  static const honey = Color(0xffffc85c);
  static const muted = Color(0xffe7d6d0);
  static const inset = 16.0;
}

// Godot destroys its engine when its SurfaceView detaches from the window.
// Keep one hybrid-composition view attached to the root overlay between visits.
class _RunnerOverlay {
  static OverlayEntry? _entry;
  static OverlayState? _owner;
  static bool _visible = false;

  static void show(BuildContext context) {
    _visible = true;
    final owner = Overlay.of(context, rootOverlay: true);
    if (_owner != owner) {
      _owner = owner;
      _entry = OverlayEntry(
        builder: (_) => Offstage(
          offstage: !_visible,
          child: PlatformViewLink(
            viewType: 'in.stage.cityrunner/view',
            surfaceFactory: (_, controller) => AndroidViewSurface(
              controller: controller as AndroidViewController,
              gestureRecognizers:
                  const <Factory<OneSequenceGestureRecognizer>>{},
              hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            ),
            onCreatePlatformView: (params) =>
                PlatformViewsService.initExpensiveAndroidView(
                    id: params.id,
                    viewType: 'in.stage.cityrunner/view',
                    layoutDirection: TextDirection.ltr,
                    onFocus: () => params.onFocusChanged(true),
                  )
                  ..addOnPlatformViewCreatedListener(
                    params.onPlatformViewCreated,
                  )
                  ..create(),
          ),
        ),
      );
      owner.insert(_entry!);
    } else {
      _entry!.markNeedsBuild();
    }
  }

  static void hide() {
    _visible = false;
    _entry?.markNeedsBuild();
  }
}

class CityRunnerScreen extends StatefulWidget {
  const CityRunnerScreen({
    super.key,
    required this.manifest,
    required this.onExit,
    this.beforeNativeLaunch,
    this.afterNativeExit,
    this.onEvent,
  });

  final void Function(String name, Map<String, dynamic> properties)? onEvent;
  final Uri manifest;
  final VoidCallback onExit;
  final Future<void> Function()? beforeNativeLaunch, afterNativeExit;

  @override
  State<CityRunnerScreen> createState() => _CityRunnerScreenState();
}

class _CityRunnerScreenState extends State<CityRunnerScreen>
    with WidgetsBindingObserver {
  final _native = NativeRunner();
  CityDownloads? _downloads;
  RunnerCity? _selected;
  String _query = '';
  String? _error;
  bool _loading = true, _working = false, _playing = false;
  bool _cancelRequested = false;
  bool _engineInstalled = false, _installingEngine = false;
  int _engineReceived = 0, _engineTotal = 0;
  double _progress = 0;
  int? _bytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NativeRunner.channel.setMethodCallHandler((call) async {
      if (call.method == 'engineProgress' && _installingEngine && mounted) {
        final progress = Map<String, dynamic>.from(call.arguments as Map);
        setState(() {
          _engineReceived = progress['received'] as int;
          _engineTotal = progress['total'] as int;
        });
      }
      if (call.method == 'gameEvent' && _playing && mounted) {
        final event = Map<String, dynamic>.from(call.arguments as Map);
        _event(event.remove('name') as String, event);
      }
    });
    _load();
  }

  void _event(String name, [Map<String, dynamic> properties = const {}]) {
    try {
      widget.onEvent?.call(name, Map.unmodifiable(properties));
    } catch (_) {
      // Host analytics must never interrupt downloads or gameplay.
    }
  }

  String _code(Object error) => switch (error) {
    DownloadCancelled() => 'cancelled',
    PlatformException() => 'native_error',
    FormatException() => 'invalid_content',
    _ => 'unavailable',
  };

  Future<void> _load() async {
    final clock = Stopwatch()..start();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = CityDownloads(await _native.cacheRoot(), _native.verify);
      try {
        _engineInstalled = await _native.engineInstalled();
        await store.load(widget.manifest);
      } catch (_) {
        store.dispose();
        rethrow;
      }
      if (!mounted) {
        store.dispose();
        return;
      }
      _event('catalogue_result', {
        'result_state': 'success',
        'duration_ms': clock.elapsedMilliseconds,
        'error_code': 'none',
      });
      _downloads?.dispose();
      setState(() {
        _downloads = store;
        _loading = false;
      });
    } catch (error) {
      _event('catalogue_result', {
        'result_state': 'failure',
        'duration_ms': clock.elapsedMilliseconds,
        'error_code': _code(error),
      });
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _select(RunnerCity city, {bool track = true}) async {
    setState(() {
      _selected = city;
      _bytes = null;
      _error = null;
    });
    final bytes = await _downloads!.downloadBytes(city);
    if (mounted && _selected == city) {
      setState(() => _bytes = bytes);
      if (track) {
        _event('city_selected', {
          'city_id': city.id,
          'download_bytes': bytes,
          'cache_hit': bytes == 0,
        });
      }
    }
  }

  Future<void> _play() async {
    final city = _selected!;
    _cancelRequested = false;
    setState(() {
      _working = true;
      _error = null;
      _progress = 0;
    });
    final clock = Stopwatch()..start();
    final bytes = _bytes ?? 0;
    final download = {
      'city_id': city.id,
      'download_bytes': bytes,
      'cache_hit': bytes == 0,
    };
    var installed = false;
    var launching = false;
    _event('download_requested', download);
    try {
      if (!_engineInstalled) {
        setState(() {
          _installingEngine = true;
          _engineReceived = 0;
          _engineTotal = 0;
        });
        await _native.installEngine();
        _engineInstalled = true;
        if (mounted) setState(() => _installingEngine = false);
      }
      if (!mounted || _cancelRequested) throw DownloadCancelled();
      final files = await _downloads!.install(city, (received, total) {
        if (mounted) setState(() => _progress = received / total);
      });
      installed = true;
      _event('download_result', {
        ...download,
        'result_state': 'success',
        'duration_ms': clock.elapsedMilliseconds,
        'error_code': 'none',
      });
      if (!mounted || _cancelRequested) return;
      launching = true;
      _event('launch_requested', {'city_id': city.id});
      await widget.beforeNativeLaunch?.call();
      if (!mounted || _cancelRequested) {
        _event('launch_cancelled');
        return;
      }
      setState(() => _playing = true);
      _RunnerOverlay.show(context);
      try {
        await _native.launch(city.id, files);
      } finally {
        _RunnerOverlay.hide();
        if (mounted) setState(() => _playing = false);
        await widget.afterNativeExit?.call();
      }
      _event('native_closed');
      if (mounted) await _select(city, track: false);
    } on DownloadCancelled catch (error) {
      _event('download_result', {
        ...download,
        'result_state': 'cancelled',
        'duration_ms': clock.elapsedMilliseconds,
        'error_code': _code(error),
      });
      if (mounted) await _select(city, track: false);
    } catch (error) {
      if (!installed) {
        _event('download_result', {
          ...download,
          'result_state': 'failure',
          'duration_ms': clock.elapsedMilliseconds,
          'error_code': _code(error),
        });
      } else if (launching) {
        _event('native_error', {'error_code': _code(error)});
      }
      if (mounted) {
        setState(
          () => _error = error is PlatformException
              ? error.message ?? 'City Runner could not download. Please retry.'
              : '$error',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _installingEngine = false;
        });
      }
    }
  }

  Future<void> _remove() async {
    final clock = Stopwatch()..start();
    final city = _selected!;
    setState(() => _working = true);
    try {
      await _downloads!.remove(_selected!);
      _event('cache_remove_result', {
        'city_id': city.id,
        'result_state': 'success',
        'duration_ms': clock.elapsedMilliseconds,
        'error_code': 'none',
      });
      if (mounted) await _select(city, track: false);
    } catch (error) {
      _event('cache_remove_result', {
        'city_id': city.id,
        'result_state': 'failure',
        'duration_ms': clock.elapsedMilliseconds,
        'error_code': _code(error),
      });
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_playing && _working && state == AppLifecycleState.paused) {
      _cancel();
    }
  }

  void _cancel() {
    _cancelRequested = true;
    if (_installingEngine) _native.cancelEngine();
    _downloads?.cancel();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_playing) _native.close();
    NativeRunner.channel.setMethodCallHandler(null);
    _event('chooser_closed');
    _cancel();
    _downloads?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_playing) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (popped, result) {
          if (!popped) _native.back();
        },
        child: const ColoredBox(color: RunnerTheme.background),
      );
    }
    final cities = (_downloads?.cities ?? [])
        .where(
          (city) => '${city.name} ${city.localName} ${city.state}'
              .toLowerCase()
              .contains(_query.toLowerCase()),
        )
        .toList();
    return PopScope(
      canPop: !_working,
      onPopInvokedWithResult: (popped, result) {
        if (!popped && !_playing) _cancel();
      },
      child: Scaffold(
        backgroundColor: RunnerTheme.background,
        appBar: AppBar(
          title: const Text('City Runner'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _working ? _cancel : widget.onExit,
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(RunnerTheme.inset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Pick your city. Find your stride.',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Only your selected city downloads. Scenic prototype routes; '
                  'not exact street replicas.',
                  style: TextStyle(color: RunnerTheme.muted),
                ),
                const SizedBox(height: 16),
                TextField(
                  enabled: !_working,
                  decoration: const InputDecoration(labelText: 'Search cities'),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 8),
                if (_loading) const LinearProgressIndicator(),
                Expanded(
                  child: ListView.builder(
                    itemCount: cities.length,
                    itemBuilder: (context, index) {
                      final city = cities[index];
                      return ListTile(
                        selected: city == _selected,
                        selectedTileColor: RunnerTheme.surface,
                        title: Text(city.name),
                        subtitle: Text('${city.localName} · ${city.state}'),
                        trailing: city == _selected
                            ? const Icon(Icons.check_circle)
                            : null,
                        onTap: _working ? null : () => _select(city),
                      );
                    },
                  ),
                ),
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: const TextStyle(color: RunnerTheme.cream),
                  ),
                  TextButton(
                    onPressed: _working
                        ? null
                        : (_downloads == null ? _load : _play),
                    child: const Text('Retry'),
                  ),
                ],
                if (_selected != null) ...[
                  if (!_engineInstalled)
                    const Text(
                      'First play also downloads the game engine from Google Play. '
                      'Its download size appears below when available. '
                      'The engine stays installed for other cities.',
                    ),
                  Text(
                    _bytes == null
                        ? 'Checking saved files…'
                        : _bytes == 0
                        ? 'Saved on this device. Verified before play.'
                        : 'Download up to ${(_bytes! / 1048576).toStringAsFixed(2)} MiB '
                              '(city + any missing shared resources).',
                  ),
                  const SizedBox(height: 8),
                  if (_working && !_playing) ...[
                    if (_installingEngine) ...[
                      LinearProgressIndicator(
                        value: _engineTotal > 0
                            ? _engineReceived / _engineTotal
                            : null,
                      ),
                      Text(
                        _engineTotal > 0
                            ? 'Engine: ${(_engineReceived / 1048576).toStringAsFixed(2)} / '
                                  '${(_engineTotal / 1048576).toStringAsFixed(2)} MiB'
                            : 'Preparing engine download with Google Play…',
                      ),
                    ] else ...[
                      LinearProgressIndicator(value: _progress),
                      Text('City: ${(_progress * 100).toStringAsFixed(0)}%'),
                    ],
                    TextButton(onPressed: _cancel, child: const Text('Cancel')),
                  ] else ...[
                    FilledButton(
                      onPressed: _working || _bytes == null ? null : _play,
                      child: Text(
                        _bytes == 0 && _engineInstalled
                            ? 'Play city'
                            : 'Download & play',
                      ),
                    ),
                    TextButton(
                      onPressed: _working ? null : _remove,
                      child: const Text('Remove city'),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
