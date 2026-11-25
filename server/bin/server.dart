import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:server_core/server_core.dart';

const _avatarHelp = '''
Prepara imágenes como avatares (JPG cuadrado de 512 x 512 px) y las deja en data/avatars.

Uso:
  server.exe avatar <imagen> [<imagen>...] [opciones]
  server.exe avatar --arreglar

Opciones:
  --id <nombre>       Nombre del avatar (solo con una imagen). Sin él se usa el del archivo.
  --ajustar           La imagen entera, centrada, con bordes (por defecto se recorta).
  --zoom <n>          Acerca el recorte (1 a 8; por defecto 1).
  --x <n>, --y <n>    Desplaza el recorte, de -1 (izquierda/arriba) a 1 (derecha/abajo).
  --fondo <color>     Para bordes y transparencias: difuminado, oscuro, blanco o negro.
  --reemplazar        Sustituye el avatar si ya existe.
  --arreglar          Convierte las imágenes de la carpeta que no cumplan (PNG, WebP, JPG de otro
                      tamaño...). Los originales pasan a data/avatars/originales.
''';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args[0] == 'avatar') {
    exit(await _avatarCommand(args.sublist(1)));
  }
  final root = args.isNotEmpty ? args[0] : p.join(Directory.current.path, 'videos');
  final port = args.length > 1 ? int.parse(args[1]) : 8080;
  // Clave de TMDB: tercer argumento o variable de entorno TMDB_KEY.
  final tmdbKey = args.length > 2 ? args[2] : Platform.environment['TMDB_KEY'];
  final server = MediaServer(ServerConfig(
      root: root,
      port: port,
      tmdbKey: tmdbKey,
      openAccess: Platform.environment['LUMEN_OPEN'] != '0', // =0: pedir PIN
      dataDir: p.join(Directory.current.path, 'data')));
  try {
    await server.start();
  } on StateError catch (e) {
    print('${e.message} Uso: server.exe <carpeta> [puerto]');
    exit(1);
  }
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
}

/// `server.exe avatar ...`: recorta/centra imágenes sin arrancar el servidor.
Future<int> _avatarCommand(List<String> args) async {
  final files = <String>[];
  String? id;
  var crop = const AvatarCrop();
  var overwrite = false, fix = false;

  String? value(int i, String flag) {
    if (i >= args.length) {
      stderr.writeln('Falta el valor de $flag.');
      return null;
    }
    return args[i];
  }

  var i = 0;
  while (i < args.length) {
    final a = args[i++];
    switch (a) {
      case '-h':
      case '--ayuda':
        print(_avatarHelp);
        return 0;
      case '--ajustar':
        crop = crop.copyWith(fit: AvatarFit.contain);
      case '--reemplazar':
        overwrite = true;
      case '--arreglar':
        fix = true;
      case '--id':
        id = value(i++, a);
        if (id == null) return 64;
      case '--zoom':
      case '--x':
      case '--y':
        final raw = value(i++, a);
        final n = raw == null ? null : double.tryParse(raw.replaceAll(',', '.'));
        if (n == null) {
          stderr.writeln('El valor de $a tiene que ser un número.');
          return 64;
        }
        crop = a == '--zoom'
            ? crop.copyWith(zoom: n)
            : (a == '--x' ? crop.copyWith(dx: n) : crop.copyWith(dy: n));
      case '--fondo':
        final raw = value(i++, a)?.toLowerCase();
        const names = {
          'difuminado': AvatarBackground.blur,
          'oscuro': AvatarBackground.dark,
          'blanco': AvatarBackground.white,
          'negro': AvatarBackground.black,
        };
        if (raw == null || !names.containsKey(raw)) {
          stderr.writeln('--fondo admite: ${names.keys.join(', ')}.');
          return 64;
        }
        crop = crop.copyWith(background: names[raw]);
      default:
        if (a.startsWith('--')) {
          stderr.writeln('Opción desconocida: $a\n$_avatarHelp');
          return 64;
        }
        files.add(a);
    }
  }

  final workshop = AvatarWorkshop(p.join(Directory.current.path, 'data', 'avatars'));
  if (fix) {
    final res = await workshop.fixFolder();
    if (res.isEmpty) print('No hay nada que arreglar en ${workshop.dir.path}.');
    for (final r in res) {
      print('${r.ok ? 'OK   ' : 'ERROR'} ${r.file}: ${r.message}');
    }
    return res.any((r) => !r.ok) ? 1 : 0;
  }
  if (files.isEmpty) {
    print(_avatarHelp);
    return 64;
  }
  if (id != null && files.length > 1) {
    stderr.writeln('--id solo se puede usar con una imagen.');
    return 64;
  }

  var failed = 0;
  for (final f in files) {
    try {
      final saved = await workshop.importFile(f, id: id, crop: crop, overwrite: overwrite);
      print('OK    ${p.basename(f)} -> ${p.join(workshop.dir.path, '$saved.jpg')}');
    } on FormatException catch (e) {
      failed++;
      stderr.writeln('ERROR ${p.basename(f)}: ${e.message}');
    } on StateError catch (e) {
      failed++;
      stderr.writeln('ERROR ${p.basename(f)}: ${e.message} (usa --reemplazar para sustituirlo)');
    } catch (e) {
      failed++;
      stderr.writeln('ERROR ${p.basename(f)}: $e');
    }
  }
  return failed == 0 ? 0 : 1;
}