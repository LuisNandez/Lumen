import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared/shared.dart';

// ---------------------------------------------------------------------------
//  Herramienta de avatares: recorta o centra CUALQUIER imagen (JPG, PNG, WebP,
//  GIF, BMP, TIFF, ICO...) y la deja como el servidor la quiere: JPG cuadrado de
//  512 x 512 px, sRGB, sin transparencia y de menos de 2 MB.
//
//  Tres piezas:
//   - [AvatarTool]: convierte bytes en bytes (corre en un isolate para no
//     congelar la ventana del servidor).
//   - [AvatarWorkshop]: trabaja sobre la carpeta de avatares (importar un archivo,
//     elegir un id libre, arreglar de golpe las imágenes que no cumplen).
//   - [AvatarCrop]: cómo recortar (zoom y desplazamiento) o ajustar (con bordes).
// ---------------------------------------------------------------------------

/// Cómo se encaja la imagen en el cuadrado.
enum AvatarFit {
  /// Llena el cuadrado y recorta lo que sobra (lo normal para fotos).
  cover,

  /// La imagen entera, centrada, y el resto del cuadrado se rellena con un fondo
  /// (útil para logos o imágenes que no se pueden recortar).
  contain,
}

/// Fondo para los bordes de [AvatarFit.contain] y para las transparencias.
enum AvatarBackground {
  /// La propia imagen ampliada y desenfocada (solo en [AvatarFit.contain]; con
  /// [AvatarFit.cover] las transparencias salen sobre [dark]).
  blur,
  dark,
  white,
  black,
}

/// Parámetros del recorte.
///
/// En [AvatarFit.cover] el cuadrado visible mide `min(ancho, alto) / zoom` píxeles de
/// la imagen original. [dx] y [dy] (de -1 a 1) lo desplazan por el margen que queda
/// libre: 0 = centrado, -1 = pegado a la izquierda/arriba, 1 = a la derecha/abajo.
/// Como son fracciones, valen igual para una vista previa reducida y para el original.
class AvatarCrop {
  const AvatarCrop({
    this.fit = AvatarFit.cover,
    this.zoom = 1,
    this.dx = 0,
    this.dy = 0,
    this.background = AvatarBackground.blur,
  });

  final AvatarFit fit;

  /// 1 = el cuadrado más grande que cabe; 2 = la mitad de lado (el doble de cerca).
  final double zoom;
  final double dx, dy;
  final AvatarBackground background;

  AvatarCrop copyWith(
          {AvatarFit? fit,
          double? zoom,
          double? dx,
          double? dy,
          AvatarBackground? background}) =>
      AvatarCrop(
          fit: fit ?? this.fit,
          zoom: zoom ?? this.zoom,
          dx: dx ?? this.dx,
          dy: dy ?? this.dy,
          background: background ?? this.background);
}

/// Imagen ya leída: una vista previa (PNG de hasta 1024 px) para el editor y el
/// tamaño real del original, ya girada según su orientación EXIF.
class AvatarSource {
  const AvatarSource(this.preview, this.width, this.height);
  final Uint8List preview;
  final int width, height;
}

/// Resultado de procesar un archivo con [AvatarWorkshop.fixFolder].
class AvatarFixResult {
  const AvatarFixResult(this.file, this.ok, this.message, {this.id});
  final String file;
  final bool ok;
  final String message;

  /// Id del avatar generado (solo si [ok]).
  final String? id;
}

double _cl(double v, double lo, double hi) {
  if (v.isNaN) return lo;
  return v < lo ? lo : (v > hi ? hi : v);
}

int _ci(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

class AvatarTool {
  const AvatarTool._();

  /// Extensiones que se saben leer.
  static const extensions = [
    'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'tif', 'tiff', 'ico', 'tga'
  ];

  /// Lado más largo de la vista previa para el editor.
  static const previewMaxSide = 1024;

  static const jpegQuality = 88;

  /// Más que esto no se intenta ni abrir (evita agotar la memoria con una foto de
  /// panorámica de 300 MB).
  static const maxInputBytes = 64 * 1024 * 1024;

  /// Lee la imagen y prepara la vista previa para el editor.
  /// Lanza [FormatException] (con un mensaje para mostrar) si no se puede leer.
  static Future<AvatarSource> prepare(Uint8List bytes) =>
      Isolate.run(() => _prepare(bytes));

  /// Genera el JPG final de [avatarPixels] x [avatarPixels] px.
  /// Lanza [FormatException] si no se puede leer la imagen.
  static Future<Uint8List> render(Uint8List bytes,
          [AvatarCrop crop = const AvatarCrop()]) =>
      Isolate.run(() => _render(bytes, crop));
}

// ---------------------------------------------------------------------------
//  Trabajo pesado (se ejecuta dentro de un isolate)
// ---------------------------------------------------------------------------

img.Image _decode(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const FormatException('El archivo está vacío.');
  }
  img.Image? im;
  try {
    im = img.decodeImage(bytes);
  } catch (_) {
    im = null;
  }
  if (im == null) {
    throw const FormatException(
        'No se pudo leer la imagen (formato no compatible o archivo dañado). '
        'Prueba con JPG, PNG, WebP, GIF o BMP.');
  }
  // GIF animado: nos quedamos con el primer fotograma.
  if (im.numFrames > 1) im = im.frames.first;
  // Móviles y cámaras guardan la foto "de lado" con una marca EXIF: la giramos de verdad.
  im = img.bakeOrientation(im);
  if (im.width < 1 || im.height < 1) {
    throw const FormatException('La imagen no tiene tamaño.');
  }
  return im;
}

AvatarSource _prepare(Uint8List bytes) {
  final im = _decode(bytes);
  final w = im.width, h = im.height;
  var small = im;
  if (math.max(w, h) > AvatarTool.previewMaxSide) {
    small = w >= h
        ? img.copyResize(im,
            width: AvatarTool.previewMaxSide,
            interpolation: img.Interpolation.average)
        : img.copyResize(im,
            height: AvatarTool.previewMaxSide,
            interpolation: img.Interpolation.average);
  }
  return AvatarSource(
      Uint8List.fromList(img.encodePng(small, level: 1)), w, h);
}

Uint8List _render(Uint8List bytes, AvatarCrop crop) {
  final src = _decode(bytes);
  return _encode(_compose(src, crop));
}

img.Color _solid(AvatarBackground b) {
  switch (b) {
    case AvatarBackground.white:
      return img.ColorRgba8(255, 255, 255, 255);
    case AvatarBackground.black:
      return img.ColorRgba8(0, 0, 0, 255);
    case AvatarBackground.dark:
    case AvatarBackground.blur:
      return img.ColorRgba8(32, 32, 36, 255);
  }
}

/// Recorta un cuadrado de [side] px con su esquina en ([x0], [y0]) y lo lleva a
/// [size] x [size].
img.Image _squareTo(img.Image src, double x0, double y0, double side, int size) {
  final w = src.width, h = src.height;
  final sideI = _ci(side.round(), 1, math.min(w, h));
  final x = _ci(x0.round(), 0, w - sideI);
  final y = _ci(y0.round(), 0, h - sideI);
  final cropped = img.copyCrop(src, x: x, y: y, width: sideI, height: sideI);
  if (sideI == size) return cropped;
  return img.copyResize(cropped,
      width: size,
      height: size,
      interpolation:
          sideI > size ? img.Interpolation.average : img.Interpolation.cubic);
}

img.Image _compose(img.Image srcIn, AvatarCrop crop) {
  const size = avatarPixels;
  final src = srcIn.convert(format: img.Format.uint8, numChannels: 4);
  final w = src.width, h = src.height;

  if (crop.fit == AvatarFit.cover) {
    final zoom = _cl(crop.zoom, 1, 8);
    final side = math.min(w, h) / zoom;
    final x0 = (w - side) / 2 * (1 + _cl(crop.dx, -1, 1));
    final y0 = (h - side) / 2 * (1 + _cl(crop.dy, -1, 1));
    final piece = _squareTo(src, x0, y0, side, size);
    final canvas = img.Image(width: size, height: size, numChannels: 4);
    img.fill(canvas, color: _solid(crop.background)); // por si hay transparencias
    img.compositeImage(canvas, piece);
    return canvas;
  }

  // contain: la imagen entera, centrada
  img.Image canvas;
  if (crop.background == AvatarBackground.blur) {
    final side = math.min(w, h).toDouble();
    final bg = _squareTo(src, (w - side) / 2, (h - side) / 2, side, size);
    canvas = img.gaussianBlur(bg, radius: 24);
  } else {
    canvas = img.Image(width: size, height: size, numChannels: 4);
    img.fill(canvas, color: _solid(crop.background));
  }
  final scale = size / math.max(w, h);
  final tw = _ci((w * scale).round(), 1, size);
  final th = _ci((h * scale).round(), 1, size);
  final fitted = (tw == w && th == h)
      ? src
      : img.copyResize(src,
          width: tw,
          height: th,
          interpolation:
              scale < 1 ? img.Interpolation.average : img.Interpolation.cubic);
  img.compositeImage(canvas, fitted,
      dstX: (size - tw) ~/ 2, dstY: (size - th) ~/ 2);
  return canvas;
}

/// JPG de calidad 88; si por algún motivo pasara de 2 MB, baja la calidad.
Uint8List _encode(img.Image im) {
  var q = AvatarTool.jpegQuality;
  while (true) {
    final bytes = Uint8List.fromList(img.encodeJpg(im, quality: q));
    if (bytes.length <= avatarMaxBytes || q <= 40) return bytes;
    q -= 10;
  }
}

// ---------------------------------------------------------------------------
//  La carpeta de avatares
// ---------------------------------------------------------------------------

/// Operaciones sobre la carpeta de avatares. No necesita que el servidor esté en
/// marcha (la usa también la herramienta de línea de comandos).
class AvatarWorkshop {
  AvatarWorkshop(String path) : dir = Directory(path);

  final Directory dir;

  /// Subcarpeta donde [fixFolder] guarda los originales que ha convertido.
  static const originalsFolder = 'originales';

  static const _accentsFrom = 'áàäâãåÁÀÄÂÃÅéèëêÉÈËÊíìïîÍÌÏÎóòöôõÓÒÖÔÕúùüûÚÙÜÛñÑçÇ';
  static const _accentsTo = 'aaaaaaAAAAAAeeeeEEEEiiiiIIIIoooooOOOOOuuuuUUUUnNcC';

  /// Id válido (letras, números, `-` y `_`) a partir del nombre de un archivo:
  /// quita acentos y cambia lo demás por `_`.
  static String suggestId(String fileName) {
    var s = p.basenameWithoutExtension(fileName);
    final b = StringBuffer();
    for (final r in s.runes) {
      final c = String.fromCharCode(r);
      final i = _accentsFrom.indexOf(c);
      b.write(i >= 0 ? _accentsTo[i] : c);
    }
    s = b
        .toString()
        .replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    if (s.length > 40) s = s.substring(0, 40);
    s = s.replaceAll(RegExp(r'^_+|_+$'), '');
    return s.isEmpty ? 'avatar' : s;
  }

  /// ¿Ya hay un avatar con ese id? (sin distinguir mayúsculas, como Windows).
  /// [exceptPath] se ignora: es el archivo que se va a sustituir.
  bool isTaken(String id, {String? exceptPath}) {
    if (!dir.existsSync()) return false;
    final want = id.toLowerCase();
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        if (exceptPath != null && p.equals(e.path, exceptPath)) continue;
        final ext = p.extension(e.path).toLowerCase();
        if (ext != '.jpg' && ext != '.jpeg') continue;
        if (p.basenameWithoutExtension(e.path).toLowerCase() == want) return true;
      }
    } catch (_) {}
    return false;
  }

  /// [base] si está libre; si no, `base_2`, `base_3`...
  String uniqueId(String base, {String? exceptPath}) {
    if (!isTaken(base, exceptPath: exceptPath)) return base;
    final root = base.length > 36 ? base.substring(0, 36) : base;
    for (var i = 2; i < 1000; i++) {
      final id = '${root}_$i';
      if (!isTaken(id, exceptPath: exceptPath)) return id;
    }
    return '${root}_${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<Uint8List> _read(String path) async {
    final f = File(path);
    if (!f.existsSync()) throw FormatException('No existe el archivo: $path');
    if (f.lengthSync() > AvatarTool.maxInputBytes) {
      throw FormatException(
          'La imagen pesa demasiado (máximo ${AvatarTool.maxInputBytes ~/ (1024 * 1024)} MB).');
    }
    return f.readAsBytes();
  }

  /// Lee una imagen para el editor.
  Future<AvatarSource> open(String path) async =>
      AvatarTool.prepare(await _read(path));

  /// Recorta/centra la imagen de [path] y la guarda como `<id>.jpg` en la carpeta.
  /// Sin [id] elige uno libre a partir del nombre del archivo. Con un [id] que ya
  /// existe falla, salvo que [overwrite] sea true. Devuelve el id guardado.
  Future<String> importFile(String path,
      {String? id,
      AvatarCrop crop = const AvatarCrop(),
      bool overwrite = false}) async {
    final String finalId;
    if (id == null || id.trim().isEmpty) {
      finalId = uniqueId(suggestId(path));
    } else {
      finalId = id.trim();
      if (!isValidAvatarId(finalId)) {
        throw const FormatException(
            'El nombre solo admite letras, números, - y _ (máximo 64 caracteres).');
      }
      if (!overwrite && isTaken(finalId)) {
        throw StateError('Ya existe un avatar llamado "$finalId".');
      }
    }
    final jpg = await AvatarTool.render(await _read(path), crop);
    _write(finalId, jpg);
    return finalId;
  }

  /// Escribe `<id>.jpg` sin dejar nunca un archivo a medias en la carpeta
  /// (se escribe oculto y luego se renombra).
  void _write(String id, Uint8List jpg) {
    dir.createSync(recursive: true);
    final target = File(p.join(dir.path, '$id.jpg'));
    final tmp = File(p.join(dir.path, '.$id.tmp'));
    tmp.writeAsBytesSync(jpg, flush: true);
    try {
      // Si había un .jpeg con el mismo id, también se sustituye.
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File &&
            p.extension(e.path).toLowerCase() == '.jpeg' &&
            p.basenameWithoutExtension(e.path).toLowerCase() == id.toLowerCase()) {
          e.deleteSync();
        }
      }
      if (target.existsSync()) target.deleteSync();
      tmp.renameSync(target.path);
    } catch (_) {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
  }

  /// Convierte, con recorte centrado, todas las imágenes de la carpeta que no
  /// cumplan (PNG/WebP/GIF/BMP..., JPG que no sea de 512 x 512, o con un nombre no
  /// válido). Los originales se mueven a la subcarpeta [originalsFolder]; los que ya
  /// están bien no se tocan.
  Future<List<AvatarFixResult>> fixFolder() async {
    final out = <AvatarFixResult>[];
    if (!dir.existsSync()) return out;
    final files = dir.listSync(followLinks: false).whereType<File>().toList()
      ..sort((a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()));
    for (final f in files) {
      final name = p.basename(f.path);
      if (name.startsWith('.')) continue;
      final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
      if (!AvatarTool.extensions.contains(ext)) continue;
      try {
        final bytes = await _read(f.path);
        final isJpg = ext == 'jpg' || ext == 'jpeg';
        final stem = p.basenameWithoutExtension(name);
        final nameOk = isValidAvatarId(stem);

        if (isJpg && nameOk && bytes.length <= avatarMaxBytes) {
          final info = await AvatarTool.prepare(bytes);
          if (info.width == avatarPixels && info.height == avatarPixels) continue;
        }

        final jpg = await AvatarTool.render(bytes);
        final base = nameOk ? stem : suggestId(stem);
        final id = uniqueId(base, exceptPath: f.path);

        // Primero se aparta el original y luego se escribe el nuevo.
        final backup = Directory(p.join(dir.path, originalsFolder))
          ..createSync(recursive: true);
        var dest = File(p.join(backup.path, name));
        for (var i = 2; dest.existsSync(); i++) {
          dest = File(p.join(
              backup.path, '${p.basenameWithoutExtension(name)}_$i.${ext}'));
        }
        f.renameSync(dest.path);
        _write(id, jpg);
        out.add(AvatarFixResult(name, true, 'convertido a $id.jpg', id: id));
      } on FormatException catch (e) {
        out.add(AvatarFixResult(name, false, e.message));
      } catch (e) {
        out.add(AvatarFixResult(name, false, '$e'));
      }
    }
    return out;
  }
}
