import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Windows: talks to the OctoSnap Camera helper (OctoSnapCamera.exe, Canon EDSDK)
/// on http://127.0.0.1:5514. The helper ships next to octosnap_booth.exe (or in a
/// `camera\` subfolder) and is started hidden by the app when it isn't already running.
///
/// Endpoints used: GET /status, POST /liveview/start|stop, GET /liveview.jpg,
/// POST /capture {"autofocus":true,"name":"app-…"}, GET /files/NAME.
/// Photos taken with the CAMERA'S OWN shutter button are downloaded by the helper as
/// `cap-*.jpg` and show up in /status → lastCapture; app captures are named `app-*`.
class CanonHelper {
  CanonHelper._();
  static final instance = CanonHelper._();

  static const port = 5514;
  static const base = 'http://127.0.0.1:$port';

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..idleTimeout = const Duration(seconds: 2)
    ..findProxy = ((_) => 'DIRECT'); // never send localhost traffic through a proxy

  String? _lastSeenCapture; // lastCapture.name already handled
  bool _baselineSet = false;
  int _lastFrameId = -1;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPoll = DateTime.fromMillisecondsSinceEpoch(0);
  Process? _proc;
  bool _launchTried = false;

  /// Full path of OctoSnapCamera.exe next to the app (or in camera\), or null.
  String? helperExe() {
    try {
      final dir = File(Platform.resolvedExecutable).parent.path;
      for (final p in ['$dir\\OctoSnapCamera.exe', '$dir\\camera\\OctoSnapCamera.exe']) {
        if (File(p).existsSync()) return p;
      }
    } catch (_) {}
    return null;
  }

  Future<HttpClientResponse> _req(String method, String path,
      {Object? json, Duration timeout = const Duration(seconds: 3)}) async {
    final rq = await _http.openUrl(method, Uri.parse('$base$path')).timeout(timeout);
    if (json != null) {
      final body = utf8.encode(jsonEncode(json));
      rq.headers.contentType = ContentType.json;
      rq.contentLength = body.length;
      rq.add(body);
    }
    return rq.close().timeout(timeout);
  }

  Future<Uint8List> _bytes(HttpClientResponse r, Duration timeout) async {
    final b = BytesBuilder(copy: false);
    await r.forEach(b.add).timeout(timeout);
    return b.takeBytes();
  }

  Future<Map<String, dynamic>> _json(String method, String path,
      {Object? body, Duration timeout = const Duration(seconds: 3)}) async {
    final r = await _req(method, path, json: body, timeout: timeout);
    final b = await _bytes(r, timeout);
    final j = jsonDecode(utf8.decode(b));
    return j is Map<String, dynamic> ? j : <String, dynamic>{};
  }

  /// /status, or null when the helper isn't answering.
  Future<Map<String, dynamic>?> status({Duration timeout = const Duration(milliseconds: 1500)}) async {
    try {
      final j = await _json('GET', '/status', timeout: timeout);
      return j['app'] == 'octosnap-camera' ? j : null;
    } catch (_) {
      return null;
    }
  }

  /// Starts OctoSnapCamera.exe hidden if it isn't answering yet. Returns true when it answers.
  Future<bool> ensureRunning({Duration wait = const Duration(seconds: 10)}) async {
    if (!Platform.isWindows) return false;
    if (await status() != null) return true;
    final exe = helperExe();
    if (exe == null) return false;
    if (_proc == null || !_launchTried) {
      _launchTried = true;
      try {
        final log = '${Directory.systemTemp.path}\\octosnap-camera.log';
        _proc = await Process.start(exe, ['--log', log],
            workingDirectory: File(exe).parent.path, mode: ProcessStartMode.detached);
      } catch (_) {
        return false;
      }
    }
    final until = DateTime.now().add(wait);
    while (DateTime.now().isBefore(until)) {
      await Future.delayed(const Duration(milliseconds: 400));
      if (await status() != null) return true;
    }
    _launchTried = false; // allow another launch attempt next time
    return false;
  }

  /// Human readable status line for the settings screen.
  Future<String> describe() async {
    final s = await status();
    if (s == null) {
      return helperExe() == null
          ? 'OctoSnapCamera.exe not found next to the app'
          : 'Camera helper not running (port $port)';
    }
    final sdk = s['sdk'];
    if (sdk == 'missing' || sdk == 'error') return 'EDSDK problem: ${s['sdkError'] ?? s['error']}';
    if (s['connected'] != true) return 'No camera: ${s['error'] ?? 'not connected'}';
    final bat = s['battery'];
    return '✓ ${s['model'] ?? 'Canon camera'} connected${bat != null ? ' · battery $bat%' : ''}'
        '${s['liveview'] == true ? ' · live view ${s['fps']} fps' : ''}';
  }

  /// Makes sure the helper runs and a camera is connected. Returns the model name.
  Future<String> connect() async {
    if (!await ensureRunning()) {
      throw helperExe() == null
          ? 'OctoSnapCamera.exe not found next to octosnap_booth.exe'
          : 'Camera helper did not start (port $port). Check Windows firewall / antivirus.';
    }
    Map<String, dynamic>? s;
    final until = DateTime.now().add(const Duration(seconds: 8));
    while (true) {
      s = await status();
      if (s != null) {
        final sdk = s['sdk'];
        if (sdk == 'missing' || sdk == 'error') throw 'EDSDK: ${s['sdkError'] ?? s['error']}';
        if (s['connected'] == true) break;
      }
      if (DateTime.now().isAfter(until)) throw '${s?['error'] ?? 'No Canon camera found'}';
      await Future.delayed(const Duration(milliseconds: 400));
    }
    // photos taken before the booth opened are not guest shots
    _lastSeenCapture = (s['lastCapture'] as Map?)?['name'] as String?;
    _baselineSet = true;
    return (s['model'] as String?) ?? 'Canon camera';
  }

  Future<bool> isConnected() async => (await status())?['connected'] == true;

  Future<void> startLiveView() async {
    try {
      await _json('POST', '/liveview/start', timeout: const Duration(seconds: 6));
    } catch (_) {}
  }

  /// Latest live-view JPEG (~25 fps max). Null when no NEW frame is available yet.
  Future<Uint8List?> liveFrame() async {
    final since = DateTime.now().difference(_lastFrameAt).inMilliseconds;
    if (since < 40) await Future.delayed(Duration(milliseconds: 40 - since));
    for (var attempt = 0; attempt < 3; attempt++) {
      _lastFrameAt = DateTime.now();
      final r = await _req('GET', '/liveview.jpg', timeout: const Duration(seconds: 3));
      final b = await _bytes(r, const Duration(seconds: 3));
      if (r.statusCode != 200) {
        if (r.statusCode == 503) return null; // starting / camera busy
        throw 'live view HTTP ${r.statusCode}';
      }
      final id = int.tryParse(r.headers.value('x-frame-id') ?? '') ?? -1;
      if (id >= 0 && id == _lastFrameId) {
        await Future.delayed(const Duration(milliseconds: 15));
        continue; // same frame as last time
      }
      _lastFrameId = id;
      return b.length > 800 ? b : null;
    }
    return null;
  }

  Future<Uint8List> _readCapture(Map<String, dynamic> j) async {
    final path = j['path'] as String?;
    if (path != null) {
      final f = File(path);
      for (var i = 0; i < 10; i++) {
        if (await f.exists()) return f.readAsBytes();
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    final url = j['url'] as String?;
    if (url == null) throw 'Camera photo not found';
    final r = await _req('GET', url, timeout: const Duration(seconds: 10));
    final b = await _bytes(r, const Duration(seconds: 10));
    if (r.statusCode != 200) throw 'Photo download failed (${r.statusCode})';
    return b;
  }

  /// AF + shutter, waits for the JPEG.
  Future<Uint8List> capture() async {
    final name = 'app-${DateTime.now().millisecondsSinceEpoch}';
    final j = await _json('POST', '/capture',
        body: {'autofocus': true, 'name': name}, timeout: const Duration(seconds: 30));
    if (j['ok'] != true) throw '${j['error'] ?? 'Capture failed'}';
    _lastSeenCapture = j['name'] as String? ?? '$name.jpg';
    return _readCapture(j);
  }

  /// Photo from the camera's own shutter button (helper names them cap-*.jpg), or null.
  Future<Uint8List?> pollExternal() async {
    if (DateTime.now().difference(_lastPoll).inMilliseconds < 350) return null;
    _lastPoll = DateTime.now();
    final s = await status(timeout: const Duration(seconds: 1));
    final lc = s?['lastCapture'] as Map<String, dynamic>?;
    final name = lc?['name'] as String?;
    if (lc == null || name == null) return null;
    if (!_baselineSet) {
      _lastSeenCapture = name;
      _baselineSet = true;
      return null;
    }
    if (name == _lastSeenCapture) return null;
    _lastSeenCapture = name;
    if (name.startsWith('app-')) return null; // our own capture
    try {
      return await _readCapture(lc);
    } catch (_) {
      return null;
    }
  }

  /// Leaving the booth: stop live view (helper keeps running so the next start is instant).
  Future<void> close() async {
    try {
      await _json('POST', '/liveview/stop', timeout: const Duration(seconds: 2));
    } catch (_) {}
  }
}
