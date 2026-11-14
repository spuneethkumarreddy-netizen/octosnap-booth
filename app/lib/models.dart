import 'dart:ui' show Color;

/// Paper sizes in inches (portrait width x height).
class PaperSize {
  final String name;
  final double w;
  final double h;
  const PaperSize(this.name, this.w, this.h);

  static const presets = <PaperSize>[
    PaperSize('4x6', 4, 6),
    PaperSize('6x4', 6, 4),
    PaperSize('2x6', 2, 6),
    PaperSize('4x4', 4, 4),
    PaperSize('4x8', 4, 8),
    PaperSize('5x7', 5, 7),
    PaperSize('6x6', 6, 6),
    PaperSize('6x8', 6, 8),
    PaperSize('6x9', 6, 9),
    PaperSize('A6', 4.13, 5.83),
    PaperSize('A5', 5.83, 8.27),
    PaperSize('A4', 8.27, 11.69),
  ];

  Map<String, dynamic> toJson() => {'name': name, 'w': w, 'h': h};
  factory PaperSize.fromJson(Map<String, dynamic> j) =>
      PaperSize(j['name'] as String, (j['w'] as num).toDouble(), (j['h'] as num).toDouble());
}

enum ElementType { photo, text, image }

/// A layout element. Position and size are in inches from the top-left of the sheet.
class LayoutElement {
  ElementType type;
  double x, y, w, h, rotation; // rotation in degrees
  int photoNumber; // photo boxes: which shot fills this box (1-based)
  String text; // text elements; supports {event} and {date}
  double fontSize; // points
  int color; // ARGB
  String? imagePath; // image/logo elements

  LayoutElement({
    required this.type,
    this.x = 0.5,
    this.y = 0.5,
    this.w = 2,
    this.h = 2,
    this.rotation = 0,
    this.photoNumber = 1,
    this.text = 'Text',
    this.fontSize = 24,
    this.color = 0xFF1F1F24,
    this.imagePath,
  });

  LayoutElement copy() => LayoutElement.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'rotation': rotation,
        'photoNumber': photoNumber,
        'text': text,
        'fontSize': fontSize,
        'color': color,
        'imagePath': imagePath,
      };

  factory LayoutElement.fromJson(Map<String, dynamic> j) => LayoutElement(
        type: ElementType.values.byName(j['type'] as String),
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num).toDouble(),
        h: (j['h'] as num).toDouble(),
        rotation: (j['rotation'] as num? ?? 0).toDouble(),
        photoNumber: j['photoNumber'] as int? ?? 1,
        text: j['text'] as String? ?? '',
        fontSize: (j['fontSize'] as num? ?? 24).toDouble(),
        color: j['color'] as int? ?? 0xFF1F1F24,
        imagePath: j['imagePath'] as String?,
      );
}

class PhotoLayout {
  String name;
  PaperSize paper;
  int background; // ARGB
  String? templatePath; // full-sheet PNG drawn ON TOP of photos (transparent windows)
  List<LayoutElement> elements;
  /// Photos are drawn this many mm larger than each photo box on every side (bleed for a magnet cutter).
  double bleedMm;
  /// Crop marks at every photo box's trim corners (always printed for this template).
  bool cropMarks;
  /// Pair mode: two guests share one sheet. The first shot waits; the next shot fills the
  /// second photo box and the sheet prints. Only for 1-shot templates with 2+ photo boxes.
  bool pairMode;

  PhotoLayout({
    this.name = 'Template',
    required this.paper,
    this.background = 0xFFFFFFFF,
    this.templatePath,
    List<LayoutElement>? elements,
    this.bleedMm = 0,
    this.cropMarks = false,
    this.pairMode = false,
  }) : elements = elements ?? [];

  /// True when pair mode applies to this template.
  bool get pairActive =>
      pairMode && shotCount == 1 && elements.where((e) => e.type == ElementType.photo).length >= 2;

  /// Copy for a pair-mode sheet: photo boxes in reading order alternate shot 1 / shot 2.
  PhotoLayout pairLayout() {
    final c = copy()..pairMode = false;
    final boxes = c.elements.where((e) => e.type == ElementType.photo).toList()
      ..sort((a, b) => (a.y - b.y).abs() > 0.05 ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
    for (var i = 0; i < boxes.length; i++) {
      boxes[i].photoNumber = i < boxes.length / 2 ? 1 : 2;
    }
    return c;
  }

  /// Width/height of the first photo box filled by shot [n] (1-based), or null.
  double? boxAspectForShot(int n) {
    for (final e in elements) {
      if (e.type == ElementType.photo && e.photoNumber == n && e.h > 0) {
        final turned = (e.rotation.abs() % 180 - 90).abs() < 1;
        return turned ? e.h / e.w : e.w / e.h;
      }
    }
    return null;
  }

  /// Number of shots the booth must take = highest photo number used.
  int get shotCount {
    var n = 0;
    for (final e in elements) {
      if (e.type == ElementType.photo && e.photoNumber > n) n = e.photoNumber;
    }
    return n == 0 ? 1 : n;
  }

  PhotoLayout copy() => PhotoLayout.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'name': name,
        'paper': paper.toJson(),
        'background': background,
        'templatePath': templatePath,
        'elements': elements.map((e) => e.toJson()).toList(),
        'bleedMm': bleedMm,
        'cropMarks': cropMarks,
        'pairMode': pairMode,
      };

  factory PhotoLayout.fromJson(Map<String, dynamic> j) => PhotoLayout(
        name: j['name'] as String? ?? 'Template',
        paper: PaperSize.fromJson(j['paper'] as Map<String, dynamic>),
        background: j['background'] as int? ?? 0xFFFFFFFF,
        templatePath: j['templatePath'] as String?,
        elements: (j['elements'] as List? ?? [])
            .map((e) => LayoutElement.fromJson(e as Map<String, dynamic>))
            .toList(),
        bleedMm: (j['bleedMm'] as num? ?? 0).toDouble(),
        cropMarks: j['cropMarks'] as bool? ?? false,
        pairMode: j['pairMode'] as bool? ?? false,
      );

  /// Two 2.5 x 3.5 in portrait magnets side by side on 6x4 landscape, centred,
  /// 1.5 mm bleed + crop marks at the trim (for a 2.5x3.5 magnet cutter).
  /// Default: one shot fills both boxes (1 shot = 2 magnets).
  static PhotoLayout twoMagnets() {
    const w = 2.5, h = 3.5, gap = 0.4;
    const x0 = (6 - (2 * w + gap)) / 2; // 0.3 in
    const y0 = (4 - h) / 2; // 0.25 in
    return PhotoLayout(
      name: 'Magnets 2x (2.5x3.5) on 6x4',
      paper: PaperSize.presets[1],
      bleedMm: 1.5,
      cropMarks: true,
      elements: [
        LayoutElement(type: ElementType.photo, x: x0, y: y0, w: w, h: h, photoNumber: 1),
        LayoutElement(type: ElementType.photo, x: x0 + w + gap, y: y0, w: w, h: h, photoNumber: 1),
      ],
    );
  }

  /// Six 2x2 magnets of ONE shot on a 4x6 sheet.
  static PhotoLayout sixMagnets() => PhotoLayout(
        paper: PaperSize.presets.first,
        elements: [
          for (var r = 0; r < 3; r++)
            for (var c = 0; c < 2; c++)
              LayoutElement(type: ElementType.photo, x: c * 2.0, y: r * 2.0, w: 2, h: 2, photoNumber: 1),
        ],
      );

  /// Classic 4x6 single photo with a caption strip.
  static PhotoLayout singlePhoto() => PhotoLayout(
        paper: PaperSize.presets.first,
        elements: [
          LayoutElement(type: ElementType.photo, x: 0.2, y: 0.2, w: 3.6, h: 4.8, photoNumber: 1),
          LayoutElement(type: ElementType.text, x: 0.2, y: 5.15, w: 3.6, h: 0.6, text: '{event}', fontSize: 22),
        ],
      );

  /// Classic 2x6 strip with 3 shots.
  static PhotoLayout strip3() => PhotoLayout(
        paper: PaperSize.presets[2],
        elements: [
          for (var i = 0; i < 3; i++)
            LayoutElement(type: ElementType.photo, x: 0.1, y: 0.1 + i * 1.75, w: 1.8, h: 1.65, photoNumber: i + 1),
          LayoutElement(type: ElementType.text, x: 0.1, y: 5.4, w: 1.8, h: 0.5, text: '{event}', fontSize: 14),
        ],
      );
}

/// Position (centre, 0..1 of screen), size and colour of one welcome-screen item.
class WelcomeItem {
  double x, y, scale;
  int color;
  bool visible;
  WelcomeItem({this.x = 0.5, this.y = 0.5, this.scale = 1, this.color = 0xFFFFFFFF, this.visible = true});
  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'scale': scale, 'color': color, 'visible': visible};
  factory WelcomeItem.fromJson(Map<String, dynamic>? j, WelcomeItem d) => j == null
      ? d
      : WelcomeItem(
          x: (j['x'] as num?)?.toDouble() ?? d.x,
          y: (j['y'] as num?)?.toDouble() ?? d.y,
          scale: (j['scale'] as num?)?.toDouble() ?? d.scale,
          color: j['color'] as int? ?? d.color,
          visible: j['visible'] as bool? ?? d.visible,
        );
}

class WelcomeSettings {
  WelcomeItem titleItem;
  WelcomeItem subtitleItem;
  WelcomeItem buttonItem;
  bool cameraPreview; // live camera behind the welcome text
  String title;
  String subtitle;
  String buttonText;
  int background;
  int accent;
  String? backgroundImage;
  WelcomeSettings({
    this.title = 'Welcome!',
    this.subtitle = 'Tap to make your fridge magnet',
    this.buttonText = 'START',
    this.background = 0xFF1F1F24,
    this.accent = 0xFFF47B20,
    this.backgroundImage,
    WelcomeItem? titleItem,
    WelcomeItem? subtitleItem,
    WelcomeItem? buttonItem,
    this.cameraPreview = true,
  })  : titleItem = titleItem ?? WelcomeItem(y: 0.40),
        subtitleItem = subtitleItem ?? WelcomeItem(y: 0.50, color: 0xDDFFFFFF),
        buttonItem = buttonItem ?? WelcomeItem(y: 0.64);
  Map<String, dynamic> toJson() => {
        'titleItem': titleItem.toJson(),
        'subtitleItem': subtitleItem.toJson(),
        'buttonItem': buttonItem.toJson(),
        'cameraPreview': cameraPreview,
        'title': title,
        'subtitle': subtitle,
        'buttonText': buttonText,
        'background': background,
        'accent': accent,
        'backgroundImage': backgroundImage,
      };
  factory WelcomeSettings.fromJson(Map<String, dynamic> j) => WelcomeSettings(
        title: j['title'] as String? ?? 'Welcome!',
        subtitle: j['subtitle'] as String? ?? '',
        buttonText: j['buttonText'] as String? ?? 'START',
        background: j['background'] as int? ?? 0xFF1F1F24,
        accent: j['accent'] as int? ?? 0xFFF47B20,
        backgroundImage: j['backgroundImage'] as String?,
        titleItem: WelcomeItem.fromJson(j['titleItem'] as Map<String, dynamic>?, WelcomeItem(y: 0.40)),
        subtitleItem: WelcomeItem.fromJson(j['subtitleItem'] as Map<String, dynamic>?, WelcomeItem(y: 0.50, color: 0xDDFFFFFF)),
        buttonItem: WelcomeItem.fromJson(j['buttonItem'] as Map<String, dynamic>?, WelcomeItem(y: 0.64)),
        cameraPreview: j['cameraPreview'] as bool? ?? true,
      );
}

class CaptureSettings {
  int firstCountdown; // seconds before the first shot
  int countdown; // seconds before each next shot
  double displaySeconds; // how long each shot is shown after capture
  double delayBetween; // pause between shots
  bool allowRetake;
  int finalDisplaySeconds; // how long the final sheet stays before returning to welcome
  bool showCropGuide; // darken the area outside the photo box during countdown
  bool sounds; // countdown ticks + shutter click
  String exitPin; // operator PIN to leave the booth ('' = no PIN)
  bool roaming; // Roaming (instant): live view full screen, tap anywhere / camera shutter = capture
  bool autoAccept; // roaming: skip review, go straight to compose + print
  CaptureSettings({
    this.roaming = false,
    this.autoAccept = true,
    this.showCropGuide = true,
    this.sounds = true,
    this.exitPin = '',
    this.firstCountdown = 5,
    this.countdown = 3,
    this.displaySeconds = 2,
    this.delayBetween = 1,
    this.allowRetake = true,
    this.finalDisplaySeconds = 10,
  });
  Map<String, dynamic> toJson() => {
        'firstCountdown': firstCountdown,
        'countdown': countdown,
        'displaySeconds': displaySeconds,
        'delayBetween': delayBetween,
        'allowRetake': allowRetake,
        'finalDisplaySeconds': finalDisplaySeconds,
        'showCropGuide': showCropGuide,
        'sounds': sounds,
        'exitPin': exitPin,
        'roaming': roaming,
        'autoAccept': autoAccept,
      };
  factory CaptureSettings.fromJson(Map<String, dynamic> j) => CaptureSettings(
        firstCountdown: j['firstCountdown'] as int? ?? 5,
        countdown: j['countdown'] as int? ?? 3,
        displaySeconds: (j['displaySeconds'] as num? ?? 2).toDouble(),
        delayBetween: (j['delayBetween'] as num? ?? 1).toDouble(),
        allowRetake: j['allowRetake'] as bool? ?? true,
        finalDisplaySeconds: j['finalDisplaySeconds'] as int? ?? 10,
        showCropGuide: j['showCropGuide'] as bool? ?? true,
        sounds: j['sounds'] as bool? ?? true,
        exitPin: j['exitPin'] as String? ?? '',
        roaming: j['roaming'] as bool? ?? false,
        autoAccept: j['autoAccept'] as bool? ?? true,
      );
}

enum CameraSource { builtIn, usbDslr }

class CameraSettings {
  CameraSource source;
  String? cameraName; // built-in camera id/name chosen by the operator
  bool mirrorPreview;
  bool mirrorPhoto;
  int quarterTurns; // rotate preview/photo by 90° steps
  CameraSettings({
    this.source = CameraSource.builtIn,
    this.cameraName,
    this.mirrorPreview = true,
    this.mirrorPhoto = false,
    this.quarterTurns = 0,
  });
  Map<String, dynamic> toJson() => {
        'source': source.name,
        'cameraName': cameraName,
        'mirrorPreview': mirrorPreview,
        'mirrorPhoto': mirrorPhoto,
        'quarterTurns': quarterTurns,
      };
  factory CameraSettings.fromJson(Map<String, dynamic> j) => CameraSettings(
        source: CameraSource.values.byName(j['source'] as String? ?? 'builtIn'),
        cameraName: j['cameraName'] as String?,
        mirrorPreview: j['mirrorPreview'] as bool? ?? true,
        mirrorPhoto: j['mirrorPhoto'] as bool? ?? false,
        quarterTurns: j['quarterTurns'] as int? ?? 0,
      );
}

class PrintSettings {
  bool autoPrint;
  int copies;
  String? printerUrl; // desktop direct printing
  String? printerName;
  bool twoPerPage; // e.g. two 2x6 strips on one 4x6
  bool cutMarks; // edge ticks at every photo-box edge, for cutting magnets
  double offsetXmm; // printer calibration: + moves the print right
  double offsetYmm; // printer calibration: + moves the print down
  double scalePct; // printer calibration: 100 = exact size
  bool usePrinterSettings; // Windows: use the printer driver's own defaults (paper / borderless)
  PrintSettings({
    this.autoPrint = false,
    this.copies = 1,
    this.printerUrl,
    this.printerName,
    this.twoPerPage = false,
    this.cutMarks = false,
    this.offsetXmm = 0,
    this.offsetYmm = 0,
    this.scalePct = 100,
    this.usePrinterSettings = false,
  });
  Map<String, dynamic> toJson() => {
        'usePrinterSettings': usePrinterSettings,
        'autoPrint': autoPrint,
        'copies': copies,
        'printerUrl': printerUrl,
        'printerName': printerName,
        'twoPerPage': twoPerPage,
        'cutMarks': cutMarks,
        'offsetXmm': offsetXmm,
        'offsetYmm': offsetYmm,
        'scalePct': scalePct,
      };
  factory PrintSettings.fromJson(Map<String, dynamic> j) => PrintSettings(
        autoPrint: j['autoPrint'] as bool? ?? false,
        copies: j['copies'] as int? ?? 1,
        printerUrl: j['printerUrl'] as String?,
        printerName: j['printerName'] as String?,
        usePrinterSettings: j['usePrinterSettings'] as bool? ?? false,
        twoPerPage: j['twoPerPage'] as bool? ?? false,
        cutMarks: j['cutMarks'] as bool? ?? false,
        offsetXmm: (j['offsetXmm'] as num? ?? 0).toDouble(),
        offsetYmm: (j['offsetYmm'] as num? ?? 0).toDouble(),
        scalePct: (j['scalePct'] as num? ?? 100).toDouble(),
      );
}

class BoothEvent {
  final String id;
  String name;
  DateTime date;
  WelcomeSettings welcome;
  /// All templates of this event. When there are several, guests choose one after tapping Start.
  List<PhotoLayout> layouts;
  int activeLayout; // the template being edited / used
  CaptureSettings capture;
  CameraSettings camera;
  PrintSettings print;

  BoothEvent({
    required this.id,
    required this.name,
    required this.date,
    WelcomeSettings? welcome,
    PhotoLayout? layout,
    List<PhotoLayout>? layouts,
    this.activeLayout = 0,
    CaptureSettings? capture,
    CameraSettings? camera,
    PrintSettings? print,
  })  : welcome = welcome ?? WelcomeSettings(),
        layouts = (layouts != null && layouts.isNotEmpty) ? layouts : [layout ?? PhotoLayout.sixMagnets()],
        capture = capture ?? CaptureSettings(),
        camera = camera ?? CameraSettings(),
        print = print ?? PrintSettings() {
    activeLayout = activeLayout.clamp(0, this.layouts.length - 1);
  }

  PhotoLayout get layout => layouts[activeLayout.clamp(0, layouts.length - 1)];
  set layout(PhotoLayout l) => layouts[activeLayout.clamp(0, layouts.length - 1)] = l;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'date': date.toIso8601String(),
        'welcome': welcome.toJson(),
        'layouts': layouts.map((l) => l.toJson()).toList(),
        'activeLayout': activeLayout,
        'capture': capture.toJson(),
        'camera': camera.toJson(),
        'print': print.toJson(),
      };

  factory BoothEvent.fromJson(Map<String, dynamic> j) => BoothEvent(
        id: j['id'] as String,
        name: j['name'] as String,
        date: DateTime.tryParse(j['date'] as String? ?? '') ?? DateTime.now(),
        welcome: WelcomeSettings.fromJson(j['welcome'] as Map<String, dynamic>? ?? {}),
        layout: j['layout'] == null ? null : PhotoLayout.fromJson(j['layout'] as Map<String, dynamic>),
        layouts: (j['layouts'] as List?)?.map((l) => PhotoLayout.fromJson(l as Map<String, dynamic>)).toList(),
        activeLayout: j['activeLayout'] as int? ?? 0,
        capture: CaptureSettings.fromJson(j['capture'] as Map<String, dynamic>? ?? {}),
        camera: CameraSettings.fromJson(j['camera'] as Map<String, dynamic>? ?? {}),
        print: PrintSettings.fromJson(j['print'] as Map<String, dynamic>? ?? {}),
      );
}

const brandOrange = Color(0xFFF47B20);
const brandCharcoal = Color(0xFF1F1F24);
