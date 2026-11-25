import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'native.dart';
import 'sounds.dart';

// ---------- Descubrimiento (broadcast UDP) ----------
class DiscoveredServer {
  const DiscoveredServer(this.host, this.info);
  final String host;
  final ServerInfo info;
  String get address => '$host:${info.port}';
}

Future<List<DiscoveredServer>> discoverServers(
    {Duration timeout = const Duration(milliseconds: 2000)}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final found = <String, DiscoveredServer>{};
  final sub = socket.listen((e) {
    if (e != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    try {
      final info = ServerInfo.fromJson(
          jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>);
      final s = DiscoveredServer(d.address.address, info);
      found[s.address] = s;
    } catch (_) {}
  });
  final msg = utf8.encode(discoveryRequest);
  final target = InternetAddress('255.255.255.255');
  socket.send(msg, target, discoveryPort);
  await Future.delayed(timeout ~/ 2);
  socket.send(msg, target, discoveryPort); // UDP puede perder paquetes
  await Future.delayed(timeout ~/ 2);
  await sub.cancel();
  socket.close();
  return found.values.toList();
}

// ---------- Sesión persistente ----------
class Session {
  const Session(this.host, this.name, this.token);
  final String host, name, token;
}

final prefsProvider =
    Provider<SharedPreferences>((_) => throw UnimplementedError('override en main'));

class SessionNotifier extends Notifier<Session?> {
  @override
  Session? build() {
    final p = ref.read(prefsProvider);
    final host = p.getString('host'), token = p.getString('token');
    if (host == null || token == null) return null;
    return Session(host, p.getString('name') ?? host, token);
  }

  Future<void> save(Session s) async {
    final p = ref.read(prefsProvider);
    await p.setString('host', s.host);
    await p.setString('name', s.name);
    await p.setString('token', s.token);
    state = s;
  }

  /// Borra el token pero recuerda el último host para rellenarlo al reconectar.
  Future<void> clear() async {
    final p = ref.read(prefsProvider);
    await p.remove('token');
    await p.remove('name');
    await p.remove('tmdbKey');
    await p.remove('tmdbLang');
    await p.remove('profile_username');
    state = null;
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, Session?>(SessionNotifier.new);

final apiProvider = Provider<Api?>((ref) {
  final s = ref.watch(sessionProvider);
  return s == null ? null : Api(s.host, s.token);
});

final libraryProvider = FutureProvider.autoDispose<List<VideoItem>>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return [];
  try {
    return await api.library();
  } on UnauthorizedException {
    // Token revocado o servidor reiniciado sin tokens.json: volver a emparejar.
    Future.microtask(() => ref.read(sessionProvider.notifier).clear());
    rethrow;
  }
});

/// Series de la biblioteca. Depende de [libraryProvider]: cuando el servidor avisa de
/// cambios (o termina de identificar), ambos se refrescan juntos.
final showsProvider = FutureProvider.autoDispose<List<ShowItem>>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return [];
  await ref.watch(libraryProvider.future);
  try {
    return await api.shows();
  } catch (_) {
    return []; // servidor antiguo sin /api/shows
  }
});

/// Novedades: capítulos nuevos de series que ya estaban en la biblioteca (campanita).
/// Depende de [libraryProvider]: se recalcula al cambiar la biblioteca, al terminar un
/// video (cambia lo visto) y al cambiar de perfil.
final newsProvider = FutureProvider.autoDispose<NewsData>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return const NewsData();
  await ref.watch(libraryProvider.future);
  try {
    return await api.news();
  } catch (_) {
    return const NewsData(); // servidor antiguo sin /api/news
  }
});

/// Una serie con todos sus capítulos.
final showDetailProvider =
    FutureProvider.autoDispose.family<ShowDetail, String>((ref, id) async {
  final api = ref.watch(apiProvider);
  if (api == null) throw StateError('Sin sesión');
  await ref.watch(libraryProvider.future);
  return api.show(id);
});

/// Clave de TMDB que el servidor entrega a los dispositivos emparejados. Se guarda aquí
/// para poder explorar el catálogo y pedir títulos aunque el servidor esté apagado.
class TmdbCreds {
  const TmdbCreds(this.key, this.language);
  final String key, language;
}

class TmdbCredsNotifier extends Notifier<TmdbCreds?> {
  @override
  TmdbCreds? build() {
    final p = ref.read(prefsProvider);
    final k = p.getString('tmdbKey');
    if (k == null || k.isEmpty) return null;
    return TmdbCreds(k, p.getString('tmdbLang') ?? 'es-MX');
  }

  /// Pide la clave al servidor (si está encendido) y la guarda.
  Future<void> sync() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      final c = await api.tmdbCreds();
      final p = ref.read(prefsProvider);
      if (c == null) {
        // El servidor no tiene clave configurada.
        await p.remove('tmdbKey');
        state = null;
        return;
      }
      await p.setString('tmdbKey', c.key);
      await p.setString('tmdbLang', c.language);
      state = TmdbCreds(c.key, c.language);
    } catch (_) {
      // servidor antiguo (sin /api/tmdb/key) o sin conexión: se conserva lo guardado
    }
  }
}

final tmdbCredsProvider =
    NotifierProvider<TmdbCredsNotifier, TmdbCreds?>(TmdbCredsNotifier.new);

/// Info del servidor (p. ej. si tiene TMDB configurado). null si no se pudo consultar.
final serverInfoProvider = FutureProvider.autoDispose<ServerInfo?>((ref) async {
  final s = ref.watch(sessionProvider);
  if (s == null) return null;
  try {
    return await Api.info(s.host);
  } catch (_) {
    return null;
  }
});

/// Ajustes de la app (se guardan en el dispositivo).
class AppSettings {
  const AppSettings(
      {this.parallelDownloads = 1,
      this.autoResumeDownloads = true,
      this.subtitleScale = 1.0,
      this.soundsEnabled = true});

  /// Cuántas descargas bajan a la vez (1 a 3).
  final int parallelDownloads;

  /// Reanudar solas las descargas interrumpidas cuando el servidor vuelve a estar encendido.
  final bool autoResumeDownloads;

  /// Tamaño de los subtítulos: 1.0 = el de siempre, mayor = más grandes.
  final double subtitleScale;

  /// Sonidos de la interfaz (assets/sounds).
  final bool soundsEnabled;

  AppSettings copyWith(
          {int? parallelDownloads,
          bool? autoResumeDownloads,
          double? subtitleScale,
          bool? soundsEnabled}) =>
      AppSettings(
          parallelDownloads: parallelDownloads ?? this.parallelDownloads,
          autoResumeDownloads: autoResumeDownloads ?? this.autoResumeDownloads,
          subtitleScale: subtitleScale ?? this.subtitleScale,
          soundsEnabled: soundsEnabled ?? this.soundsEnabled);
}

class SettingsNotifier extends Notifier<AppSettings> {
  static const _kParallel = 'set_dl_parallel';
  static const _kAutoResume = 'set_dl_autoresume';
  static const _kSubScale = 'set_sub_scale';

  @override
  AppSettings build() {
    final p = ref.read(prefsProvider);
    return AppSettings(
        parallelDownloads: (p.getInt(_kParallel) ?? 1).clamp(1, 3).toInt(),
        autoResumeDownloads: p.getBool(_kAutoResume) ?? true,
        subtitleScale:
            (p.getDouble(_kSubScale) ?? 1.0).clamp(1.0, 2.5).toDouble(),
        soundsEnabled: p.getBool(Sfx.kPrefKey) ?? true);
  }

  /// Cambia el tamaño de los subtítulos (1.0 a 2.5). El reproductor lo aplica al instante.
  void setSubtitleScale(double s) {
    final v = ((s.clamp(1.0, 2.5)) * 100).round() / 100;
    if (v == state.subtitleScale) return;
    ref.read(prefsProvider).setDouble(_kSubScale, v);
    state = state.copyWith(subtitleScale: v);
  }

  void setParallel(int n) {
    final v = n.clamp(1, 3).toInt();
    ref.read(prefsProvider).setInt(_kParallel, v);
    state = state.copyWith(parallelDownloads: v);
  }

  void setSounds(bool v) {
    ref.read(prefsProvider).setBool(Sfx.kPrefKey, v);
    Sfx.enabled = v;
    state = state.copyWith(soundsEnabled: v);
    if (v) Sfx.play(Snd.notificacion, force: true); // de muestra al activarlos
  }

  void setAutoResume(bool v) {
    ref.read(prefsProvider).setBool(_kAutoResume, v);
    state = state.copyWith(autoResumeDownloads: v);
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

final discoveryProvider =
    FutureProvider.autoDispose<List<DiscoveredServer>>((ref) => discoverServers());

/// Nombre estable de este dispositivo (se usa al emparejar y en el control remoto).
String deviceName(SharedPreferences p) {
  var n = p.getString('deviceName');
  if (n == null) {
    n = '${Platform.operatingSystem}-${Random().nextInt(9000) + 1000}';
    p.setString('deviceName', n);
  }
  return n;
}

/// Con qué nombre firma este dispositivo sus peticiones: el nombre de usuario del perfil
/// activo o, si el servidor aún no tiene perfiles, el nombre del dispositivo.
String requesterName(SharedPreferences p) =>
    p.getString('profile_username') ?? deviceName(p);

/// Nombres genéricos que se generaban antes ("android-1234"): se cambian por el nombre real.
final _genericName = RegExp(r'^[a-z]+-\d{4}$');

/// Al arrancar: si el nombre guardado es genérico, lo sustituye por el del teléfono
/// ("POCO X8 Pro"). El servidor actualiza solo el nombre de los dispositivos ya emparejados.
Future<void> ensureDeviceName(SharedPreferences p) async {
  final cur = p.getString('deviceName');
  if (cur != null && !_genericName.hasMatch(cur)) return;
  final real = await NativeBridge.deviceName();
  if (real != null) await p.setString('deviceName', real);
}
