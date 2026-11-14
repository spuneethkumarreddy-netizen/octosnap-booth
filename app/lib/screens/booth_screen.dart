import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../compositor.dart';
import '../dslr.dart';
import '../models.dart';
import '../print_service.dart';
import '../storage.dart';
import 'capture_settings_screen.dart';
import 'layouts_screen.dart';
import 'print_setup_screen.dart';
import 'welcome_editor_screen.dart';

enum _Stage { welcome, choose, countdown, review, processing, done }

/// Live guest flow: welcome → countdown → flash → review (retake/keep) → sheet → print.
/// Operator exit: press and hold the top-left corner for 2 seconds.
class BoothScreen extends StatefulWidget {
  final BoothEvent event;
  const BoothScreen({super.key, required this.event});
  @override
  State<BoothScreen> createState() => _BoothScreenState();
}

class _BoothScreenState extends State<BoothScreen> {
  CameraController? ctl;
  String? cameraError;
  // USB DSLR state
  bool _dslr = false;
  bool _dslrBusy = false; // pause live view while the shutter fires
  Uint8List? _liveFrame;
  String? _dslrName;
  _Stage stage = _Stage.welcome;
  int countdown = 0;
  int shotIndex = 0;
  bool flash = false;
  Uint8List? reviewShot;
  Uint8List? finalSheet;
  Completer<bool>? _reviewChoice; // true = keep
  bool _alive = true;
  Timer? _exitTimer;
  Timer? _idleTimer;
  DateTime? _cornerDown;
  bool _suppressTap = false;
  int _session = 0; // bumped to cancel a running session
  final Map<PhotoLayout, Future<Uint8List>> _thumbs = {};
  int _homeLayout = 0; // operator's active template, restored after each guest session
  // Build 9: roaming, camera-shutter trigger, pair mode
  bool _roamBusy = false;
  Uint8List? _lastSheet; // roaming: last sheet (thumbnail)
  Uint8List? _pendingPair; // pair mode: first shot waiting for its partner
  Uint8List? _externalShot; // photo from the camera's own shutter, consumed by a running session

  static final _triggerKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.audioVolumeUp,
    LogicalKeyboardKey.audioVolumeDown,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaPlay,
    LogicalKeyboardKey.mediaTrackNext,
    LogicalKeyboardKey.mediaTrackPrevious,
    LogicalKeyboardKey.camera,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };

  bool get _live => _alive && mounted;

  BoothEvent get e => widget.event;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable().catchError((_) {});
    _initCamera();
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _toast('Operator menu (edit / exit): press Back, or hold the top-left corner for 2 seconds'));
  }

  /// Bluetooth/USB clicker, keyboard or volume key = shutter.
  bool _onKey(KeyEvent ev) {
    if (ev is! KeyDownEvent || !_live) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return false; // a dialog / editor is open
    if (!_triggerKeys.contains(ev.logicalKey)) return false;
    _trigger();
    return true;
  }

  void _trigger() {
    if (stage == _Stage.review) {
      if (_reviewChoice?.isCompleted == false) _reviewChoice!.complete(true);
      return;
    }
    if (e.capture.roaming) {
      if (stage == _Stage.welcome) _roamCapture();
      return;
    }
    if (stage == _Stage.welcome) {
      _onStart();
    } else if (stage == _Stage.done) {
      _reset();
    }
  }

  /// A photo arrived from the camera's own shutter button.
  Future<void> _onExternalShot(Uint8List bytes) async {
    if (!_live) return;
    if (e.capture.roaming) {
      var waited = 0;
      while (_roamBusy && _live && waited++ < 100) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (stage == _Stage.welcome) await _roamCapture(external: bytes);
      return;
    }
    switch (stage) {
      case _Stage.welcome:
      case _Stage.choose:
        if (stage == _Stage.choose) setState(() => stage = _Stage.welcome);
        _homeLayout = e.activeLayout;
        unawaited(_runSession(firstShot: bytes));
      case _Stage.countdown:
        _externalShot = bytes;
      default:
        _toast('Camera photo ignored (finish this session first)');
    }
  }

  bool get _camReady => _dslr ? _liveFrame != null : (ctl?.value.isInitialized ?? false);

  Future<void> _initCamera() async {
    if (e.camera.source == CameraSource.usbDslr && Dslr.supported) {
      try {
        _dslrName = await Dslr.connect();
        await Dslr.startLiveView();
        if (!mounted) return;
        setState(() => _dslr = true);
        _toast('$_dslrName connected');
        _liveLoop();
        return;
      } catch (err) {
        _toast('DSLR not found, using built-in camera. ($err)');
      }
    }
    await _initBuiltIn();
  }

  /// Pulls live-view frames from the DSLR; falls back to built-in camera if it disconnects.
  Future<void> _liveLoop() async {
    var errors = 0;
    var n = 0;
    while (_live && _dslr) {
      if (_dslrBusy) {
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }
      // Every few frames: did the operator press the camera's own shutter?
      if (++n % 3 == 0) {
        try {
          final x = await Dslr.pollExternal();
          if (x != null && _live) {
            if (e.capture.sounds) SystemSound.play(SystemSoundType.click);
            unawaited(_onExternalShot(x));
          }
        } catch (_) {}
      }
      try {
        final f = await Dslr.liveFrame();
        errors = 0;
        if (f != null && _live && !_dslrBusy) setState(() => _liveFrame = f);
        if (f == null) await Future.delayed(const Duration(milliseconds: 60));
      } catch (err) {
        if (++errors >= 6) {
          await _dslrLost();
          return;
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  Future<void> _dslrLost() async {
    if (!_live) return;
    _session++;
    await Dslr.close();
    setState(() {
      _dslr = false;
      _liveFrame = null;
      stage = _Stage.welcome;
    });
    _toast('DSLR disconnected — switched to built-in camera');
    await _initBuiltIn();
  }

  Future<Uint8List> _takePhoto() async {
    if (_dslr) {
      _dslrBusy = true;
      try {
        return await Dslr.capture();
      } finally {
        _dslrBusy = false;
      }
    }
    final file = await ctl!.takePicture();
    return file.readAsBytes();
  }

  Future<void> _initBuiltIn() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw 'No camera found';
      // USB DSLR (phase 2) falls back to the chosen built-in camera.
      final desc = cams.firstWhere((c) => c.name == e.camera.cameraName,
          orElse: () => cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first));
      final c = CameraController(desc, ResolutionPreset.max, enableAudio: false);
      await c.initialize();
      try {
        await c.setFlashMode(FlashMode.off);
      } catch (_) {}
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => ctl = c);
    } catch (err) {
      if (mounted) setState(() => cameraError = '$err');
    }
  }

  @override
  void dispose() {
    _alive = false;
    HardwareKeyboard.instance.removeHandler(_onKey);
    _exitTimer?.cancel();
    _idleTimer?.cancel();
    ctl?.dispose();
    if (_dslr) Dslr.close();
    WakelockPlus.disable().catchError((_) {});
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _wait(double seconds) => Future.delayed(Duration(milliseconds: (seconds * 1000).round()));

  /// Welcome tapped: let the guest choose a template when there are several.
  void _onStart() {
    if (_suppressTap || !_camReady || stage != _Stage.welcome) return;
    _homeLayout = e.activeLayout;
    if (e.layouts.length > 1) {
      setState(() => stage = _Stage.choose);
    } else {
      _runSession();
    }
  }

  void _chooseLayout(int i) {
    if (stage != _Stage.choose) return;
    e.activeLayout = i;
    setState(() => stage = _Stage.welcome);
    _runSession();
  }

  Future<void> _runSession({Uint8List? firstShot}) async {
    if ((!_camReady && firstShot == null) || stage != _Stage.welcome) return;
    final my = ++_session;
    bool ok() => _live && my == _session;
    final total = e.layout.pairActive ? 1 : e.layout.shotCount;
    final shots = <Uint8List>[];
    _externalShot = null;
    var pre = firstShot;
    for (shotIndex = 0; shotIndex < total && ok();) {
      // countdown (skipped when the camera's shutter already delivered this shot)
      final secs = pre != null ? 0 : (shotIndex == 0 ? e.capture.firstCountdown : e.capture.countdown);
      setState(() => stage = _Stage.countdown);
      for (countdown = secs; countdown > 0 && ok() && _externalShot == null; countdown--) {
        setState(() {});
        if (e.capture.sounds) SystemSound.play(SystemSoundType.click);
        await _wait(1);
      }
      if (!ok()) return;
      setState(() => countdown = 0);
      // capture + flash
      Uint8List bytes;
      try {
        setState(() => flash = true);
        if (e.capture.sounds) {
          SystemSound.play(SystemSoundType.click);
          HapticFeedback.mediumImpact();
        }
        final ext = pre ?? _externalShot;
        pre = null;
        _externalShot = null;
        bytes = ext ?? await _takePhoto();
      } catch (err) {
        setState(() => flash = false);
        _toast('Capture failed: $err');
        setState(() => stage = _Stage.welcome);
        return;
      }
      await _wait(0.15);
      if (!ok()) return;
      setState(() {
        flash = false;
        reviewShot = bytes;
        stage = _Stage.review;
      });
      var keep = true;
      if (e.capture.allowRetake) {
        _reviewChoice = Completer<bool>();
        // auto-keep if nobody taps within 15 s
        keep = await _reviewChoice!.future.timeout(const Duration(seconds: 15), onTimeout: () => true);
      } else {
        await _wait(e.capture.displaySeconds);
      }
      if (!ok()) return;
      if (keep) {
        shots.add(bytes);
        shotIndex++;
        if (shotIndex < total) await _wait(e.capture.delayBetween);
      }
    }
    if (!ok()) return;
    setState(() => stage = _Stage.processing);
    try {
      final sheet = await _processShots(shots);
      if (!ok()) return;
      if (sheet == null) {
        // pair mode: first half saved, waits for the next guest
        _reset();
        return;
      }
      setState(() {
        finalSheet = sheet;
        stage = _Stage.done;
      });
      if (e.print.autoPrint) unawaited(_print());
      _idleTimer?.cancel();
      _idleTimer = Timer(Duration(seconds: e.capture.finalDisplaySeconds), _reset);
    } catch (err) {
      _toast('Could not build sheet: $err');
      _reset();
    }
  }

  /// Builds and saves the sheet. Pair mode: returns null while the first shot waits for its partner.
  Future<Uint8List?> _processShots(List<Uint8List> shots) async {
    final layout = e.layout;
    var use = shots;
    PhotoLayout? lay;
    if (layout.pairActive) {
      if (_pendingPair == null) {
        setState(() => _pendingPair = shots.first);
        await _save(null, shots);
        _toast('Photo saved. It prints together with the NEXT photo (pair mode).');
        return null;
      }
      use = [_pendingPair!, shots.first];
      lay = layout.pairLayout();
      setState(() => _pendingPair = null);
    }
    final sheet = await SheetCompositor.compose(event: e, shots: use, layout: lay);
    await _save(sheet, shots);
    return sheet;
  }

  Future<void> _save(Uint8List? sheet, List<Uint8List> shots) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final dir = EventStore.instance.photosDir.path;
    final sep = Platform.pathSeparator;
    if (sheet != null) await File('$dir$sep${e.id}_${ts}_sheet.png').writeAsBytes(sheet);
    for (var i = 0; i < shots.length; i++) {
      await File('$dir$sep${e.id}_${ts}_shot${i + 1}.jpg').writeAsBytes(shots[i]);
    }
  }

  /// Pair mode: operator prints the waiting single shot alone (it fills both boxes).
  Future<void> _forcePrintPending() async {
    final p = _pendingPair;
    if (p == null) return;
    setState(() => _pendingPair = null);
    try {
      final sheet = await SheetCompositor.compose(event: e, shots: [p]);
      await _save(sheet, const []);
      if (e.capture.roaming) setState(() => _lastSheet = sheet);
      await _print(sheet);
    } catch (err) {
      _toast('Could not print single: $err');
    }
  }

  /// Roaming: tap anywhere / shutter / clicker = photo now, no countdown.
  Future<void> _roamCapture({Uint8List? external}) async {
    if (_roamBusy || _suppressTap || stage != _Stage.welcome) return;
    if (external == null && !_camReady) return;
    final my = _session;
    setState(() => _roamBusy = true);
    try {
      setState(() => flash = true);
      if (e.capture.sounds && external == null) {
        SystemSound.play(SystemSoundType.click);
        HapticFeedback.mediumImpact();
      }
      final bytes = external ?? await _takePhoto();
      await _wait(0.12);
      if (!_live) return;
      setState(() => flash = false);
      if (!e.capture.autoAccept) {
        setState(() {
          reviewShot = bytes;
          stage = _Stage.review;
        });
        _reviewChoice = Completer<bool>();
        final keep = await _reviewChoice!.future.timeout(const Duration(seconds: 15), onTimeout: () => true);
        if (!_live) return;
        setState(() {
          stage = _Stage.welcome;
          reviewShot = null;
        });
        if (!keep || my != _session) return;
      }
      final sheet = await _processShots([bytes]);
      if (!_live || sheet == null) return;
      setState(() => _lastSheet = sheet);
      unawaited(_print(sheet));
    } catch (err) {
      _toast('Capture failed: $err');
    } finally {
      if (_live) {
        setState(() {
          _roamBusy = false;
          flash = false;
        });
      }
    }
  }

  Future<void> _showLastSheet() async {
    final s = _lastSheet;
    if (s == null) return;
    final again = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF26262D),
        content: Image.memory(s, fit: BoxFit.contain),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Close')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Print again')),
        ],
      ),
    );
    if (again == true) await _print(s);
  }

  Widget _roamView() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _roamCapture(),
      child: Stack(fit: StackFit.expand, children: [
        _preview(),
        if (_roamBusy)
          const Positioned(
            top: 24,
            left: 0,
            right: 0,
            child: Center(child: CircularProgressIndicator(color: brandOrange)),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 18,
          child: IgnorePointer(
            child: Center(
              child: Text(
                _camReady ? 'Tap anywhere to take a photo' : 'Connecting camera…',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 16, shadows: [Shadow(blurRadius: 8, color: Colors.black)]),
              ),
            ),
          ),
        ),
        if (_lastSheet != null)
          Positioned(
            right: 12,
            bottom: 12,
            child: SafeArea(
              child: GestureDetector(
                onTap: _showLastSheet,
                child: Container(
                  width: 84,
                  decoration: BoxDecoration(border: Border.all(color: Colors.white70, width: 2)),
                  child: Image.memory(_lastSheet!, fit: BoxFit.contain, gaplessPlayback: true),
                ),
              ),
            ),
          ),
        if (_pendingPair != null) _pendingChip(),
      ]),
    );
  }

  /// Pair mode: "1 waiting" chip; operator holds it to print the single now.
  Widget _pendingChip() => Positioned(
        left: 12,
        bottom: 12,
        child: SafeArea(
          child: GestureDetector(
            onTap: () => _toast('1 photo waiting for its pair. Hold to print it alone.'),
            onLongPress: _forcePrintPending,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: const Text('1 waiting · hold to print single',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );

  Future<void> _print([Uint8List? sheet]) async {
    final s = sheet ?? finalSheet;
    if (s == null) return;
    try {
      await PrintService.printSheet(s, e);
    } catch (err) {
      _toast('Print failed: $err');
    }
  }

  void _reset() {
    _idleTimer?.cancel();
    if (!_alive) return;
    if (_homeLayout < e.layouts.length) e.activeLayout = _homeLayout;
    setState(() {
      stage = _Stage.welcome;
      finalSheet = null;
      reviewShot = null;
    });
  }

  /// Guest/operator cancels the running session and returns to the welcome screen.
  Future<void> _cancelSession() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Cancel this session?'),
        content: const Text('Photos taken so far will be discarded.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Continue')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel session')),
        ],
      ),
    );
    if (yes != true || !_live) return;
    _session++; // stops the running loop
    if (_reviewChoice != null && !_reviewChoice!.isCompleted) _reviewChoice!.complete(false);
    setState(() {
      flash = false;
      countdown = 0;
    });
    _reset();
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _confirmExit() async {
    final pin = e.capture.exitPin;
    if (pin.isNotEmpty) {
      final ctl = TextEditingController();
      final entered = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Operator PIN'),
          content: TextField(
            controller: ctl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            onSubmitted: (v) => Navigator.pop(c, v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Exit booth')),
          ],
        ),
      );
      if (entered == null || !mounted) return;
      if (entered.trim() != pin) {
        _toast('Wrong PIN');
        return;
      }
    }
    await _operatorMenu();
  }

  /// Operator menu: edit the event without leaving the booth.
  Future<void> _operatorMenu() async {
    if (!_live) return;
    if (stage != _Stage.welcome && stage != _Stage.choose && stage != _Stage.done) {
      _session++; // stop a running session before editing
      _reset();
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF26262D),
      builder: (c) {
        Widget item(IconData i, String t, String v) =>
            ListTile(leading: Icon(i, color: brandOrange), title: Text(t), onTap: () => Navigator.pop(c, v));
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('OPERATOR', style: TextStyle(letterSpacing: 2, color: Colors.white54)),
            ),
            item(Icons.play_arrow, 'Resume booth', 'resume'),
            item(Icons.waving_hand, 'Edit welcome screen', 'welcome'),
            item(Icons.dashboard_customize, 'Edit templates', 'layouts'),
            item(Icons.timer, 'Capture settings', 'capture'),
            if (_pendingPair != null) item(Icons.print_outlined, 'Print waiting single now (pair mode)', 'single'),
            item(Icons.print, 'Print setup', 'print'),
            item(Icons.logout, 'Exit booth', 'exit'),
          ]),
        );
      },
    );
    if (!mounted || !_alive) return;
    Widget? screen;
    switch (choice) {
      case 'welcome':
        screen = WelcomeEditorScreen(event: e);
      case 'layouts':
        screen = LayoutsScreen(event: e);
      case 'capture':
        screen = CaptureSettingsScreen(event: e);
      case 'print':
        screen = PrintSetupScreen(event: e);
      case 'single':
        await _forcePrintPending();
        return;
      case 'exit':
        _session++;
        Navigator.pop(context);
        return;
    }
    if (screen == null || !mounted) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await Navigator.push(context, MaterialPageRoute(builder: (_) => screen!));
    await EventStore.instance.save();
    if (!_live) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _homeLayout = e.activeLayout;
    setState(() {
      _thumbs.clear();
      stage = _Stage.welcome;
    });
  }

  Widget _chooser() {
    return Container(
      color: Color(e.welcome.background),
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Row(children: [
              const Expanded(
                child: Text('Choose your design',
                    style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
              TextButton.icon(
                onPressed: () => setState(() => stage = _Stage.welcome),
                icon: const Icon(Icons.close, color: Colors.white70),
                label: const Text('Back', style: TextStyle(color: Colors.white70)),
              ),
            ]),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 320, mainAxisSpacing: 16, crossAxisSpacing: 16, childAspectRatio: 0.7),
              itemCount: e.layouts.length,
              itemBuilder: (_, i) {
                final l = e.layouts[i];
                final thumb = _thumbs.putIfAbsent(
                    l, () => SheetCompositor.compose(event: e, shots: const [], dpi: 60, layout: l));
                return GestureDetector(
                  onTap: () => _chooseLayout(i),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Color(e.welcome.accent), width: 2),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: Column(children: [
                      Expanded(
                        child: FutureBuilder<Uint8List>(
                          future: thumb,
                          builder: (_, s) => s.hasData
                              ? Image.memory(s.data!, fit: BoxFit.contain)
                              : const Center(child: CircularProgressIndicator()),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(l.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                    ]),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _preview({bool guide = true}) {
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    Widget view;
    double ar; // displayed aspect (width/height) before rotation
    if (_dslr) {
      final f = _liveFrame;
      if (f == null) return const Center(child: CircularProgressIndicator());
      ar = 3 / 2; // Canon live view is 3:2
      view = AspectRatio(aspectRatio: ar, child: Image.memory(f, gaplessPlayback: true, fit: BoxFit.fill));
    } else {
      final c = ctl;
      if (cameraError != null) {
        return Center(child: Text('Camera problem: $cameraError', style: const TextStyle(color: Colors.white)));
      }
      if (c == null || !c.value.isInitialized) return const Center(child: CircularProgressIndicator());
      ar = portrait ? 1 / c.value.aspectRatio : c.value.aspectRatio;
      view = CameraPreview(c);
    }
    final preview = Center(
      child: RotatedBox(
        quarterTurns: e.camera.quarterTurns,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(e.camera.mirrorPreview ? -1 : 1, 1, 1),
          child: view,
        ),
      ),
    );
    final boxAr = e.layout.boxAspectForShot(e.capture.roaming ? 1 : shotIndex + 1);
    if (!guide || !e.capture.showCropGuide || boxAr == null) return preview;
    return LayoutBuilder(builder: (context, cons) {
      // Displayed preview aspect (width/height) as CameraPreview lays it out.
      final shownAr = e.camera.quarterTurns.isOdd ? 1 / ar : ar;
      final pr = _fit(shownAr, cons.maxWidth, cons.maxHeight);
      final guide = _fit(boxAr, pr.width, pr.height).shift(pr.topLeft);
      return Stack(fit: StackFit.expand, children: [
        preview,
        IgnorePointer(child: CustomPaint(painter: _CropGuidePainter(guide))),
      ]);
    });
  }

  /// Largest centred rect of aspect [ar] inside a [w] x [h] area.
  static Rect _fit(double ar, double w, double h) {
    var rw = w, rh = w / ar;
    if (rh > h) {
      rh = h;
      rw = h * ar;
    }
    return Rect.fromLTWH((w - rw) / 2, (h - rh) / 2, rw, rh);
  }

  Widget _big(String t, {double size = 180}) => Text(t,
      style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          shadows: const [Shadow(blurRadius: 24, color: Colors.black87)]));

  Widget _btn(String label, Color color, VoidCallback onTap) => Flexible(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: SizedBox(
              height: 64,
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: color),
                onPressed: onTap,
                child: FittedBox(child: Text(label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700))),
              ),
            ),
          ),
        ),
      );

  /// Bottom button bar that always fits the screen width.
  Widget _bar(List<Widget> buttons) => Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: buttons),
          ),
        ),
      );

  Widget _cancelBtn() => Positioned(
        top: 0,
        right: 0,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Material(
              color: Colors.black54,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: _cancelSession,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.close, color: Colors.white),
                    SizedBox(width: 6),
                    Text('CANCEL', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _stageView() {
    switch (stage) {
      case _Stage.welcome:
        if (e.capture.roaming) return _roamView();
        return Stack(fit: StackFit.expand, children: [
          WelcomeView(s: e.welcome, onStart: _onStart, camera: _camReady ? _preview(guide: false) : null),
          if (_pendingPair != null) _pendingChip(),
        ]);
      case _Stage.choose:
        return _chooser();
      case _Stage.countdown:
        return Stack(fit: StackFit.expand, children: [
          _preview(),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Center(child: _big('${shotIndex + 1} / ${e.layout.shotCount}', size: 32)),
              ),
            ),
          ),
          if (countdown > 0) Center(child: _big('$countdown')),
          _cancelBtn(),
        ]);
      case _Stage.review:
        return Stack(fit: StackFit.expand, children: [
          Container(color: Colors.black),
          if (reviewShot != null)
            Center(
              child: RotatedBox(
                quarterTurns: e.camera.quarterTurns,
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.diagonal3Values(e.camera.mirrorPhoto ? -1 : 1, 1, 1),
                  child: Image.memory(reviewShot!, fit: BoxFit.contain),
                ),
              ),
            ),
          if (e.capture.allowRetake || e.capture.roaming)
            _bar([
              _btn('RETAKE', Colors.white24, () {
                if (_reviewChoice?.isCompleted == false) _reviewChoice!.complete(false);
              }),
              _btn('KEEP', brandOrange, () {
                if (_reviewChoice?.isCompleted == false) _reviewChoice!.complete(true);
              }),
            ]),
          _cancelBtn(),
        ]);
      case _Stage.processing:
        return const Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: brandOrange),
          SizedBox(height: 16),
          Text('Making your magnets…', style: TextStyle(fontSize: 28, color: Colors.white)),
        ]));
      case _Stage.done:
        return Stack(fit: StackFit.expand, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 110),
            child: Center(child: Image.memory(finalSheet!, fit: BoxFit.contain)),
          ),
          _bar([
            if (!e.print.autoPrint) _btn('PRINT', brandOrange, _print),
            _btn('DONE', Colors.white24, _reset),
          ]),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // Android back button / gesture → operator exit confirmation.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: KeyedSubtree(key: ValueKey(stage), child: _stageView())),
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: flash ? 1 : 0,
              duration: const Duration(milliseconds: 80),
              child: Container(color: Colors.white),
            ),
          ),
          // hidden operator exit: hold top-left corner 2 s
          Positioned(
            left: 0,
            top: 0,
            width: 90,
            height: 90,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                _cornerDown = DateTime.now();
                _exitTimer = Timer(const Duration(seconds: 2), _confirmExit);
              },
              onPointerUp: (_) {
                _exitTimer?.cancel();
                final d = _cornerDown;
                if (d != null && DateTime.now().difference(d) > const Duration(milliseconds: 800)) {
                  _suppressTap = true;
                  Future.delayed(const Duration(milliseconds: 400), () => _suppressTap = false);
                }
              },
              onPointerCancel: (_) => _exitTimer?.cancel(),
            ),
          ),
        ]),
      ),
    );
  }
}


/// Darkens everything outside [guide] and outlines it in brand orange.
class _CropGuidePainter extends CustomPainter {
  final Rect guide;
  _CropGuidePainter(this.guide);
  @override
  void paint(Canvas canvas, Size size) {
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(guide);
    canvas.drawPath(outside, Paint()..color = const Color(0x99000000));
    canvas.drawRect(
        guide,
        Paint()
          ..color = brandOrange
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3);
  }

  @override
  bool shouldRepaint(_CropGuidePainter old) => old.guide != guide;
}
