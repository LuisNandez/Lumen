import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared/shared.dart';

/// APK de actualización que el dueño deja en la carpeta `updates/`.
class ApkInfo {
  const ApkInfo(this.file, this.package, this.versionCode, this.versionName,
      this.size, this.sha256);
  final File file;
  final String package, versionName, sha256;
  final int versionCode, size;

  AppUpdateInfo toInfo() => AppUpdateInfo(
      available: true,
      packageName: package,
      versionCode: versionCode,
      versionName: versionName,
      size: size,
      sha256: sha256);
}

/// Vigila la carpeta de actualizaciones: lee la versión de cada .apk (del
/// AndroidManifest.xml binario que lleva dentro), calcula su SHA-256 y se queda
/// con el de versionCode más alto. No hace falta renombrar nada ni escribir JSON.
class UpdateStore {
  UpdateStore(String path) : dir = Directory(path) {
    dir.createSync(recursive: true);
  }
  final Directory dir;

  /// Mejor APK válido, o null si no hay.
  ApkInfo? current;

  /// APK ignorados y por qué (para mostrarlo en la ventana del servidor).
  final skipped = <String, String>{};

  final _cache = <String, ApkInfo>{}; // ruta|tamaño|mtime -> info
  Future<void>? _running;

  /// Reescanea la carpeta. Si ya hay un escaneo en curso, espera a ese.
  Future<void> scan() => _running ??= _scan().whenComplete(() => _running = null);

  Future<void> _scan() async {
    skipped.clear();
    final found = <ApkInfo>[];
    final keep = <String>{};
    List<FileSystemEntity> items;
    try {
      items = dir.listSync(followLinks: false);
    } catch (_) {
      items = const [];
    }
    for (final e in items) {
      if (e is! File || p.extension(e.path).toLowerCase() != '.apk') continue;
      final name = p.basename(e.path);
      try {
        final st = e.statSync();
        // Se está copiando todavía: se reintenta en el próximo escaneo.
        if (DateTime.now().difference(st.modified).inSeconds < 3) {
          skipped[name] = 'se está copiando';
          continue;
        }
        final key = '${e.path}|${st.size}|${st.modified.millisecondsSinceEpoch}';
        keep.add(key);
        var info = _cache[key];
        if (info == null) {
          final m = await readApkManifest(e);
          final digest = await sha256.bind(e.openRead()).first;
          info = ApkInfo(e, m.package, m.versionCode, m.versionName, st.size,
              digest.toString());
          _cache[key] = info;
        }
        found.add(info);
      } catch (err) {
        skipped[name] = '$err'.replaceFirst('FormatException: ', '');
      }
    }
    _cache.removeWhere((k, _) => !keep.contains(k));
    // Si hay APK de varios paquetes se usa el del paquete más frecuente/primero;
    // el cliente igualmente comprueba que el paquete sea el suyo.
    found.sort((a, b) => b.versionCode.compareTo(a.versionCode));
    current = found.isEmpty ? null : found.first;
  }
}

class ApkManifest {
  const ApkManifest(this.package, this.versionCode, this.versionName);
  final String package, versionName;
  final int versionCode;
}

// ---------- lector mínimo de ZIP + AXML (sin dependencias) ----------

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

/// Extrae package / versionCode / versionName de un APK. Lanza FormatException
/// si no es un APK válido.
Future<ApkManifest> readApkManifest(File apk) async {
  final raf = await apk.open();
  try {
    final len = await raf.length();
    if (len < 22) throw const FormatException('no es un ZIP');
    final tailLen = len < 65557 ? len : 65557;
    await raf.setPosition(len - tailLen);
    final tail = await raf.read(tailLen);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (_u32(tail, i) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('ZIP incompleto o dañado');
    final entries = _u16(tail, eocd + 10);
    final cdSize = _u32(tail, eocd + 12);
    final cdOff = _u32(tail, eocd + 16);
    if (entries == 0xffff || cdOff == 0xffffffff) {
      throw const FormatException('ZIP64 no soportado');
    }
    await raf.setPosition(cdOff);
    final cd = await raf.read(cdSize);
    var o = 0;
    int? method, compSize, localOff;
    for (var i = 0; i < entries && o + 46 <= cd.length; i++) {
      if (_u32(cd, o) != 0x02014b50) break;
      final nLen = _u16(cd, o + 28), xLen = _u16(cd, o + 30), cLen = _u16(cd, o + 32);
      final name = latin1.decode(cd.sublist(o + 46, o + 46 + nLen));
      if (name == 'AndroidManifest.xml') {
        method = _u16(cd, o + 10);
        compSize = _u32(cd, o + 20);
        localOff = _u32(cd, o + 42);
        break;
      }
      o += 46 + nLen + xLen + cLen;
    }
    if (localOff == null) throw const FormatException('no es un APK (falta AndroidManifest.xml)');
    await raf.setPosition(localOff);
    final lh = await raf.read(30);
    if (lh.length < 30 || _u32(lh, 0) != 0x04034b50) {
      throw const FormatException('ZIP dañado');
    }
    await raf.setPosition(localOff + 30 + _u16(lh, 26) + _u16(lh, 28));
    final comp = await raf.read(compSize!);
    final xml = Uint8List.fromList(method == 0
        ? comp
        : method == 8
            ? ZLibCodec(raw: true).decode(comp)
            : throw const FormatException('compresión no soportada'));
    return _parseManifest(xml);
  } finally {
    await raf.close();
  }
}

ApkManifest _parseManifest(Uint8List b) {
  const bad = FormatException('AndroidManifest.xml ilegible');
  if (b.length < 8 || _u16(b, 0) != 0x0003) throw bad;
  var pos = _u16(b, 2); // cabecera del documento
  List<String> strings = const [];
  while (pos + 8 <= b.length) {
    final type = _u16(b, pos), hdr = _u16(b, pos + 2), size = _u32(b, pos + 4);
    if (size < 8) throw bad;
    if (type == 0x0001) {
      strings = _stringPool(b, pos);
    } else if (type == 0x0102) {
      final body = pos + hdr;
      final name = _u32(b, body + 4);
      if (name < strings.length && strings[name] == 'manifest') {
        final aStart = _u16(b, body + 8), aSize = _u16(b, body + 10);
        final aCount = _u16(b, body + 12);
        String? pkg, vName;
        int? vCode;
        for (var i = 0; i < aCount; i++) {
          final a = body + aStart + i * aSize;
          final n = _u32(b, a + 4);
          if (n >= strings.length) continue;
          final raw = _u32(b, a + 8);
          final dtype = b[a + 15];
          final data = _u32(b, a + 16);
          String? str() {
            final idx = raw != 0xffffffff ? raw : (dtype == 0x03 ? data : -1);
            return idx >= 0 && idx < strings.length ? strings[idx] : null;
          }

          switch (strings[n]) {
            case 'package':
              pkg = str();
            case 'versionName':
              vName = str();
            case 'versionCode':
              vCode = data;
          }
        }
        if (pkg == null || vCode == null) {
          throw const FormatException('el manifest no trae package/versionCode');
        }
        return ApkManifest(pkg, vCode, vName ?? '$vCode');
      }
    }
    pos += size;
  }
  throw bad;
}

List<String> _stringPool(Uint8List b, int c) {
  final hdr = _u16(b, c + 2);
  final count = _u32(b, c + 8);
  final flags = _u32(b, c + 16);
  final start = c + _u32(b, c + 20);
  final utf8Mode = flags & 0x100 != 0;
  final out = <String>[];
  for (var i = 0; i < count; i++) {
    var o = start + _u32(b, c + hdr + i * 4);
    if (utf8Mode) {
      var n = b[o++];
      if (n & 0x80 != 0) n = ((n & 0x7f) << 8) | b[o++];
      var bl = b[o++];
      if (bl & 0x80 != 0) bl = ((bl & 0x7f) << 8) | b[o++];
      out.add(utf8.decode(b.sublist(o, o + bl), allowMalformed: true));
    } else {
      var n = _u16(b, o);
      o += 2;
      if (n & 0x8000 != 0) {
        n = ((n & 0x7fff) << 16) | _u16(b, o);
        o += 2;
      }
      final units = <int>[for (var k = 0; k < n; k++) _u16(b, o + k * 2)];
      out.add(String.fromCharCodes(units));
    }
  }
  return out;
}
