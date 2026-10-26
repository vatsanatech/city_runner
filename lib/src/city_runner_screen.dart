import 'package:flutter/material.dart';

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

class CityRunnerScreen extends StatefulWidget {
  const CityRunnerScreen({
    super.key,
    required this.manifest,
    required this.onExit,
    this.beforeNativeLaunch,
    this.afterNativeExit,
  });

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
  double _progress = 0;
  int? _bytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final store = CityDownloads(await _native.cacheRoot(), _native.verify);
      try {
        await store.load(widget.manifest);
      } catch (_) {
        store.dispose();
        rethrow;
      }
      if (!mounted) {
        store.dispose();
        return;
      }
      _downloads?.dispose();
      setState(() {
        _downloads = store;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  Future<void> _select(RunnerCity city) async {
    setState(() {
      _selected = city;
      _bytes = null;
      _error = null;
    });
    final bytes = await _downloads!.downloadBytes(city);
    if (mounted && _selected == city) setState(() => _bytes = bytes);
  }

  Future<void> _play() async {
    final city = _selected!;
    _cancelRequested = false;
    setState(() {
      _working = true;
      _error = null;
      _progress = 0;
    });
    try {
      final files = await _downloads!.install(city, (received, total) {
        if (mounted) setState(() => _progress = received / total);
      });
      if (!mounted || _cancelRequested) return;
      await widget.beforeNativeLaunch?.call();
      if (!mounted || _cancelRequested) return;
      setState(() => _playing = true);
      try {
        await _native.launch(city.id, files);
      } finally {
        if (mounted) setState(() => _playing = false);
        await widget.afterNativeExit?.call();
      }
      if (mounted) await _select(city);
    } on DownloadCancelled {
      if (mounted) await _select(city);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _remove() async {
    setState(() => _working = true);
    try {
      await _downloads!.remove(_selected!);
      if (mounted) await _select(_selected!);
    } catch (error) {
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
    _downloads?.cancel();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelRequested = true;
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
        child: const Scaffold(
          body: AndroidView(viewType: 'in.stage.cityrunner/view'),
        ),
      );
    }
    final cities =
        (_downloads?.cities ?? [])
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
                        trailing:
                            city == _selected
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
                    onPressed:
                        _working ? null : (_downloads == null ? _load : _play),
                    child: const Text('Retry'),
                  ),
                ],
                if (_selected != null) ...[
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
                    LinearProgressIndicator(value: _progress),
                    Text('${(_progress * 100).toStringAsFixed(0)}%'),
                    TextButton(onPressed: _cancel, child: const Text('Cancel')),
                  ] else ...[
                    FilledButton(
                      onPressed: _working || _bytes == null ? null : _play,
                      child: Text(
                        _bytes == 0 ? 'Play city' : 'Download & play',
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
