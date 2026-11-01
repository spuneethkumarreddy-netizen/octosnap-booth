import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../compositor.dart';
import '../models.dart';
import '../print_service.dart';
import '../storage.dart';
import 'welcome_editor_screen.dart';

enum _Stage { welcome, countdown, review, processing, done }

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

  bool get _live => _alive && mounted;

  BoothEvent get e => widget.event;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initCamera();
    WidgetsBinding.instance.addPostFrameCallback((_) => _toast('Exit booth: press Back, or hold the top-left corner for 2 seconds'));
  }

  Future<void> _initCamera() async {
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
    _exitTimer?.cancel();
    _idleTimer?.cancel();
    ctl?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _wait(double seconds) => Future.delayed(Duration(milliseconds: (seconds * 1000).round()));

  Future<void> _runSession() async {
    final c = ctl;
    if (_suppressTap || c == null || !c.value.isInitialized || stage != _Stage.welcome) return;
    final my = ++_session;
    bool ok() => _live && my == _session;
    final total = e.layout.shotCount;
    final shots = <Uint8List>[];
    for (shotIndex = 0; shotIndex < total && ok();) {
      // countdown
      final secs = shotIndex == 0 ? e.capture.firstCountdown : e.capture.countdown;
      setState(() => stage = _Stage.countdown);
      for (countdown = secs; countdown > 0 && ok(); countdown--) {
        setState(() {});
        await _wait(1);
      }
      if (!ok()) return;
      setState(() => countdown = 0);
      // capture + flash
      Uint8List bytes;
      try {
        setState(() => flash = true);
        final file = await c.takePicture();
        bytes = await file.readAsBytes();
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
      final sheet = await SheetCompositor.compose(event: e, shots: shots);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final dir = EventStore.instance.photosDir.path;
      final sep = Platform.pathSeparator;
      await File('$dir$sep${e.id}_${ts}_sheet.png').writeAsBytes(sheet);
      for (var i = 0; i < shots.length; i++) {
        await File('$dir$sep${e.id}_${ts}_shot${i + 1}.jpg').writeAsBytes(shots[i]);
      }
      if (!ok()) return;
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

  Future<void> _print() async {
    final s = finalSheet;
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
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Exit booth?'),
        content: const Text('Go back to the event settings.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Exit')),
        ],
      ),
    );
    if (yes == true && mounted) {
      _session++;
      Navigator.pop(context);
    }
  }

  Widget _preview() {
    final c = ctl;
    if (cameraError != null) {
      return Center(child: Text('Camera problem: $cameraError', style: const TextStyle(color: Colors.white)));
    }
    if (c == null || !c.value.isInitialized) return const Center(child: CircularProgressIndicator());
    return Center(
      child: RotatedBox(
        quarterTurns: e.camera.quarterTurns,
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(e.camera.mirrorPreview ? -1 : 1, 1, 1),
          child: CameraPreview(c),
        ),
      ),
    );
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
        return WelcomeView(s: e.welcome, onStart: _runSession);
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
          if (e.capture.allowRetake)
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
