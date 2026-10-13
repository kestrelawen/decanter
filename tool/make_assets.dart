// Generates Decanter's bundled assets. Pure stdlib, no package imports, so it
// runs from anywhere:  dart tool/make_assets.dart
//
// Both outputs are original content authored for this project, deliberately not
// taken from SillyTavern — their default card is AGPL-3.0 and must never be
// committed here (see README).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// --- minimal PNG encoder ---------------------------------------------------

final List<int> _crcTable = _buildCrcTable();

List<int> _buildCrcTable() {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

Uint8List _chunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final out = BytesBuilder();
  out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
  out.add(typeBytes);
  out.add(data);
  out.add(
    (ByteData(4)..setUint32(0, _crc32(<int>[...typeBytes, ...data])))
        .buffer
        .asUint8List(),
  );
  return out.toBytes();
}

/// Encodes raw RGBA bytes (length = width * height * 4) as a PNG.
Uint8List encodePng(int width, int height, Uint8List rgba) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter type: none
    raw.add(Uint8List.sublistView(rgba, y * width * 4, (y + 1) * width * 4));
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // truecolour + alpha
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);

  final out = BytesBuilder()
    ..add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', ihdr.buffer.asUint8List()))
    ..add(_chunk('IDAT', zlib_compress(raw.toBytes())))
    ..add(_chunk('IEND', <int>[]));
  return out.toBytes();
}

/// Thin wrapper so the intent reads clearly at the call site.
List<int> zlib_compress(List<int> bytes) {
  final codec = ZLibCodec(level: 6);
  return codec.encode(bytes);
}

// --- the background --------------------------------------------------------

/// A warm dusk gradient. Deliberately not blue-purple: the brief was explicit
/// that the stock "vibecode" gradient is unwelcome. Warm, low-contrast and
/// slightly darkened, so white glass highlights read against it.
class _Stop {
  const _Stop(this.at, this.r, this.g, this.b);
  final double at;
  final int r, g, b;
}

const List<_Stop> _dusk = <_Stop>[
  _Stop(0.00, 20, 15, 13),
  _Stop(0.34, 61, 35, 30),
  _Stop(0.60, 141, 72, 44),
  _Stop(0.80, 213, 139, 74),
  _Stop(0.94, 241, 199, 150),
  _Stop(1.00, 250, 231, 199),
];

List<int> _sampleGradient(double t) {
  for (var i = 0; i < _dusk.length - 1; i++) {
    final a = _dusk[i];
    final b = _dusk[i + 1];
    if (t <= b.at) {
      final span = b.at - a.at;
      final k = span <= 0 ? 0.0 : ((t - a.at) / span).clamp(0.0, 1.0);
      final e = k * k * (3 - 2 * k); // smoothstep, avoids visible banding
      return <int>[
        (a.r + (b.r - a.r) * e).round(),
        (a.g + (b.g - a.g) * e).round(),
        (a.b + (b.b - a.b) * e).round(),
      ];
    }
  }
  final last = _dusk.last;
  return <int>[last.r, last.g, last.b];
}

void writeBackground(File out, {int width = 720, int height = 1280}) {
  final rgba = Uint8List(width * height * 4);
  final glowX = width * 0.5;
  final glowY = height * 0.78;
  final glowR = height * 0.42;

  for (var y = 0; y < height; y++) {
    final t = y / (height - 1);
    final base = _sampleGradient(t);

    for (var x = 0; x < width; x++) {
      final dx = x - glowX;
      final dy = y - glowY;
      final d = math.sqrt(dx * dx + dy * dy) / glowR;

      // Soft sun glow behind the lower third, where the glass panels will sit.
      final glow = math.exp(-d * d * 2.1) * 46.0;

      // Vignette: keeps the edges quiet so the eye stays on the panels.
      final nx = (x / width - 0.5).abs() * 2;
      final ny = (y / height - 0.5).abs() * 2;
      final vignette = 1.0 - 0.30 * math.pow(nx * nx * 0.6 + ny * ny * 0.5, 1.1);

      final i = (y * width + x) * 4;
      for (var c = 0; c < 3; c++) {
        // No dithering grain: per-pixel noise is incompressible and took this
        // asset from ~200K to 1.9M. The multi-stop gradient with smoothstep
        // interpolation is already banding-free at 8-bit.
        final v = (base[c] * vignette + glow).clamp(0.0, 255.0);
        rgba[i + c] = v.round();
      }
      rgba[i + 3] = 255;
    }
  }

  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(encodePng(width, height, rgba));
  final kb = (out.lengthSync() / 1024).toStringAsFixed(0);
  stdout.writeln('wrote ${out.path} (${width}x$height, ${kb}K)');
}

// --- the sample character --------------------------------------------------

/// An original character, with a lorebook positioned to exercise several
/// injection slots at once so the in-app lore inspector has something to show.
Map<String, dynamic> sampleCard() => <String, dynamic>{
  'spec': 'chara_card_v2',
  'spec_version': '2.0',
  'data': <String, dynamic>{
    'name': 'Mira Vance',
    'description':
        'Mira Vance is a glassblower who works out of a converted boathouse on '
        'the north quay. She is in her late thirties, forearms mapped with small '
        'burn scars, hair permanently tied back. She talks about glass the way '
        'other people talk about weather — constantly, and with the assumption '
        "that you're interested. She is generous with her craft and guarded "
        'about everything else.',
    'personality':
        'Direct, exacting, warm in short bursts. Allergic to flattery. Explains '
        'things with her hands. Goes quiet when she is concentrating and does '
        'not notice you have stopped talking.',
    'scenario':
        'The boathouse workshop after dark. The furnace is still up, casting a '
        'moving orange light across the walls and the finished pieces cooling on '
        'the bench. Outside, the tide is coming in.',
    'first_mes':
        "*She doesn't look up from the rod she's turning in the furnace.*\n\n"
        "Don't stand in the doorway, you're letting the cold in. Either come in "
        "or close it.\n\n"
        '*The glass at the end of the rod is the colour of a coal that has '
        'decided to behave.*',
    'alternate_greetings': <String>[
      "*She's at the bench with a loupe, and the furnace is banked low.*\n\n"
      "You're early. Or I'm late — I've stopped being able to tell which one it "
      "is. Give me a minute and I'll get the big one lit.",
    ],
    'mes_example':
        '<START>\n{{user}}: How long have you been doing this?\n'
        '{{char}}: *She considers the question seriously, which takes a moment.*\n'
        'Sixteen years. Eleven of them badly. That\'s the part nobody mentions — '
        'you spend a decade making things that shatter before you make one that '
        "doesn't.\n"
        '<START>\n{{user}}: This one is beautiful.\n'
        '{{char}}: *She glances at the piece, then back at you, and does not '
        'thank you.*\n'
        "It's off-centre. Two degrees, maybe three. You can see it in the neck "
        'if you hold it to the light.\n\n'
        "*She holds it to the light.*\n\n"
        "See? Don't tell me it's beautiful. Tell me if you can see it.",
    'creator': 'Kestrel Agent',
    'character_version': '0.1.0',
    'tags': <String>['slice-of-life', 'craft', 'original'],
    'creator_notes':
        'Original sample character shipped with Decanter to demonstrate card '
        'parsing and lorebook activation. Not derived from any other project.',
    'extensions': <String, dynamic>{'decanter': <String, dynamic>{'sample': true}},
    'character_book': <String, dynamic>{
      'name': 'North Quay',
      'description': 'Local knowledge for the boathouse workshop.',
      'recursive_scanning': false,
      'extensions': <String, dynamic>{},
      'entries': <dynamic>[
        <String, dynamic>{
          'keys': <String>['furnace', 'kiln'],
          'content':
              'The furnace runs on reclaimed cooking oil and takes ninety '
              'minutes to reach temperature. She lights it at dusk and works '
              'until the small hours. It is the loudest thing in the building — '
              'a low roar you feel in your teeth.',
          'enabled': true,
          'constant': false,
          'insertion_order': 20,
          'position': 0,
          'extensions': <String, dynamic>{},
        },
        <String, dynamic>{
          'keys': <String>['sea glass', 'shard'],
          'content':
              'She collects sea glass off the quay on her morning walks and '
              'keeps it in a jam jar by the window. She has never used any of it '
              'in a piece. When asked why, she says the jar is doing its own '
              'work.',
          'enabled': true,
          'constant': false,
          'insertion_order': 40,
          'position': 1,
          'extensions': <String, dynamic>{},
        },
        <String, dynamic>{
          'keys': <String>['the accident', 'scar'],
          'content':
              'Eleven years ago a piece exploded off the rod and took a year of '
              'her grip with it. She rebuilt her hands around a lighter rod. She '
              'will describe the mechanics of it in detail and will not describe '
              'how it felt.',
          'enabled': true,
          'constant': false,
          'insertion_order': 60,
          // Depth injection: lands inside the chat history rather than the
          // system block, so the inspector can show both kinds at once.
          'position': 4,
          'depth': 2,
          'extensions': <String, dynamic>{},
        },
      ],
    },
  },
};

void writeSampleCard(File out) {
  out.parent.createSync(recursive: true);
  const encoder = JsonEncoder.withIndent('  ');
  out.writeAsStringSync('${encoder.convert(sampleCard())}\n');
  stdout.writeln('wrote ${out.path} (${out.lengthSync()} bytes)');
}

// --- the app icon ----------------------------------------------------------

double _sdCircle(double x, double y, double cx, double cy, double r) {
  final double dx = x - cx;
  final double dy = y - cy;
  return math.sqrt(dx * dx + dy * dy) - r;
}

double _sdBox(
  double x,
  double y,
  double cx,
  double cy,
  double halfW,
  double halfH,
) {
  final double dx = (x - cx).abs() - halfW;
  final double dy = (y - cy).abs() - halfH;
  final double ax = math.max(dx, 0.0);
  final double ay = math.max(dy, 0.0);
  return math.sqrt(ax * ax + ay * ay) + math.min(math.max(dx, dy), 0.0);
}

/// Polynomial smooth minimum — the union that rounds the joints between the
/// body, neck and stopper instead of leaving hard creases. Poured glass has no
/// sharp internal corners, and hard unions are what made the first attempt read
/// as a ball on a stick.
double _smin(double a, double b, double k) {
  final double h = _clamp01(0.5 + 0.5 * (b - a) / k);
  return b * (1 - h) + a * h - k * h * (1 - h);
}

/// Signed distance to the decanter mark.
///
/// The silhouette is the whole design: a decanter's identity is a **tapering**
/// body — wide at the base, narrowing to the shoulder — with a long neck and a
/// flat-topped stopper. A single circle for the body reads as a flask, which is
/// exactly what happened on the first attempt, so the body is built from four
/// stacked circles of decreasing radius blended together.
double _vesselSdf(double x, double y) {
  double body = _sdCircle(x, y, 0.5, 0.760, 0.205);
  body = _smin(body, _sdCircle(x, y, 0.5, 0.650, 0.190), 0.055);
  body = _smin(body, _sdCircle(x, y, 0.5, 0.545, 0.160), 0.055);
  body = _smin(body, _sdCircle(x, y, 0.5, 0.455, 0.115), 0.055);

  // Neck and stopper use much tighter blends than the body. Blending the
  // stopper with the same radius as the body fused the two into one gourd
  // shape, which lost the silhouette entirely; a tight blend leaves a visible
  // waist at the junction, which is what reads as "stoppered".
  final double neck = _sdBox(x, y, 0.5, 0.270, 0.040, 0.105);
  final double stopper = _sdCircle(x, y, 0.5, 0.145, 0.070);

  return _smin(_smin(body, neck, 0.030), stopper, 0.010);
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// Renders the icon.
///
/// Antialiasing is analytic — coverage is derived from the signed distance
/// rather than by supersampling — so every edge is smooth at any size without
/// rendering each pixel many times.
void writeIcon(
  File out, {
  required int size,
  required bool transparent,
  required double artScale,
}) {
  final rgba = Uint8List(size * size * 4);
  // One pixel expressed in the art's own coordinate space.
  final double unit = 1.0 / size;
  final double aa = unit / artScale;

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final double u = (x + 0.5) / size;
      final double v = (y + 0.5) / size;

      // Map canvas -> art space, scaled about the centre.
      final double ax = (u - 0.5) / artScale + 0.5;
      final double ay = (v - 0.5) / artScale + 0.5;

      final double d = _vesselSdf(ax, ay);
      final double coverage = _clamp01(0.5 - d / aa);

      final int i = (y * size + x) * 4;

      double sr;
      double sg;
      double sb;
      double sa;
      if (transparent) {
        sr = 0;
        sg = 0;
        sb = 0;
        sa = 0;
      } else {
        final double dcx = u - 0.5;
        final double dcy = v - 0.52;
        final double dist = math.sqrt(dcx * dcx + dcy * dcy) / 0.62;
        final double k = _clamp01(dist);
        sr = 44 + (18 - 44) * k;
        sg = 25 + (12 - 25) * k;
        sb = 17 + (9 - 17) * k;
        sa = 255;
      }

      if (coverage <= 0) {
        rgba[i] = sr.round();
        rgba[i + 1] = sg.round();
        rgba[i + 2] = sb.round();
        rgba[i + 3] = sa.round();
        continue;
      }

      // Glass body, lit from the upper left and deepening downward.
      final double t = _clamp01((ay - 0.12) / 0.85);
      double r = 250 + (168 - 250) * t;
      double g = 205 + (88 - 205) * t;
      double b = 150 + (40 - 150) * t;

      // A liquid line: everything below the fill reads deeper and more
      // saturated, with a bright meniscus where it meets the glass. This is the
      // cue that says "vessel holding something" rather than "coloured shape".
      const double fillLine = 0.62;
      final double liquid = _clamp01((ay - (fillLine - 0.012)) / 0.024);
      if (liquid > 0) {
        r += (188 - r) * liquid;
        g += (92 - g) * liquid;
        b += (34 - b) * liquid;
      } else {
        // Meniscus highlight hugging the top of the liquid.
        final double meniscus = 1 - _clamp01(-(ay - fillLine) / 0.012);
        r += (255 - r) * meniscus * 0.5;
        g += (232 - g) * meniscus * 0.5;
        b += (198 - b) * meniscus * 0.5;
      }

      // Specular highlights, all above the fill line. Reflections belong on the
      // empty glass; the first attempt put two of them under the liquid where
      // they read as floating dots — blemishes rather than light.
      for (final List<double> blob in <List<double>>[
        <double>[0.418, 0.545, 0.055, 0.85], // shoulder
        <double>[0.462, 0.430, 0.022, 0.38], // upper body
        <double>[0.489, 0.230, 0.014, 0.60], // neck glint
      ]) {
        final double hi = _sdCircle(ax, ay, blob[0], blob[1], blob[2]);
        if (hi < 0) {
          final double strength = _clamp01(-hi / blob[2]) * blob[3];
          r += (255 - r) * strength;
          g += (245 - g) * strength;
          b += (226 - b) * strength;
        }
      }

      // Rim light: brighten the last couple of pixels at the silhouette edge,
      // which is what makes an edge read as glass instead of as a shape.
      final double edge = 1 - _clamp01(d.abs() / (aa * 2.6));
      if (edge > 0) {
        r += (255 - r) * edge * 0.62;
        g += (238 - g) * edge * 0.62;
        b += (208 - b) * edge * 0.62;
      }

      final double alpha = transparent ? coverage : 1.0;
      if (!transparent) {
        r = sr + (r - sr) * coverage;
        g = sg + (g - sg) * coverage;
        b = sb + (b - sb) * coverage;
      }

      rgba[i] = r.round().clamp(0, 255);
      rgba[i + 1] = g.round().clamp(0, 255);
      rgba[i + 2] = b.round().clamp(0, 255);
      rgba[i + 3] = (alpha * 255).round().clamp(0, 255);
    }
  }

  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(encodePng(size, size, rgba));
}

/// Density buckets Android expects, per `mipmap-*`.
const Map<String, int> _legacyIconSizes = <String, int>{
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

/// Adaptive-icon foregrounds are 108dp, not 48dp, and only the inner ~66dp is
/// guaranteed visible inside an arbitrary launcher mask.
const Map<String, int> _adaptiveForegroundSizes = <String, int>{
  'mdpi': 108,
  'hdpi': 162,
  'xhdpi': 216,
  'xxhdpi': 324,
  'xxxhdpi': 432,
};

/// Writes the whole icon set into `app/android_overlay/`, which CI copies over
/// the generated `android/` tree.
///
/// An overlay rather than a committed `android/` folder, because that folder has
/// to be generated by Flutter anyway (the Gradle wrapper is a binary).
void writeIconSet(String root) {
  final String res = '$root/app/android_overlay/res';

  _legacyIconSizes.forEach((String density, int size) {
    writeIcon(
      File('$res/mipmap-$density/ic_launcher.png'),
      size: size,
      transparent: false,
      artScale: 0.95,
    );
  });

  _adaptiveForegroundSizes.forEach((String density, int size) {
    writeIcon(
      File('$res/mipmap-$density/ic_launcher_foreground.png'),
      size: size,
      transparent: true,
      // Sized to sit inside the safe zone of any launcher mask.
      artScale: 0.82,
    );
  });

  File('$res/mipmap-anydpi-v26/ic_launcher.xml')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<!-- Adaptive icon: the launcher supplies the mask, so the foreground only has
     to survive being cropped to a circle, squircle or rounded square. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');

  File('$res/values/ic_launcher_background.xml')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Matches the outer stop of the generated background gradient. -->
    <color name="ic_launcher_background">#120C09</color>
</resources>
''');

  stdout.writeln('wrote icon set under $res');
  stdout.writeln('  legacy: ${_legacyIconSizes.keys.join(", ")}');
  stdout.writeln('  adaptive foreground: ${_adaptiveForegroundSizes.keys.join(", ")}');
}

void main(List<String> args) {
  final root = Directory.current.path;
  writeBackground(File('$root/app/assets/background.png'));
  writeSampleCard(File('$root/app/assets/cards/mira_vance.json'));
  writeIconSet(root);
}
