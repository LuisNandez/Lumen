import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart' show UserProfile;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'core.dart';
import 'native.dart';
import 'profiles.dart' show profilesProvider;
import 'updater.dart';

UserProfile? _profileOf(Object? p) =>
    p is Map ? UserProfile.fromJson(p.cast<String, dynamic>()) : null;

class RemoteDevice {
  const RemoteDevice(this.id, this.name, this.state, [this.profile]);
  final String id, name;
  final Map<String, dynamic>? state; // reproducción actual, o null

  /// Perfil de usuario activo en ese dispositivo (nombre y foto), si lo dijo.
  final UserProfile? profile;
  factory RemoteDevice.fromJson(Map<String, dynamic> j) => RemoteDevice(
      j['id'] as String,
      j['name'] as String,
      (j['state'] as Map?)?.cast<String, dynamic>(),
      _profileOf(j['profile']));
}

/// Alguien sentado en una sala de "ver juntos".
class PartyMember {
  const PartyMember(this.id, this.name, this.buffering,
      [this.profile, this.voice = false, this.muted = false]);
  final String id, name; // id y nombre del dispositivo
  final bool buffering; // está cargando: la sala espera
  final UserProfile? profile;

  /// Tiene activado el chat de voz del vestíbulo, y su micrófono está en silencio.
  final bool voice, muted;

  /// Cómo se le llama: el nombre de su perfil de usuario o, si no tiene, el del dispositivo.
  String get label => profile?.username ?? name;

  factory PartyMember.fromJson(Map<String, dynamic> j) => PartyMember(
      '${j['id']}',
      '${j['name']}',
      j['buffering'] == true,
      _profileOf(j['profile']),
      j['voice'] == true,
      j['muted'] == true);
}

/// Una sala abierta en el servidor.
class PartyInfo {
  const PartyInfo({
    required this.id,
    required this.videoId,
    required this.title,
    required this.hostId,
    required this.hostName,
    required this.control,
    required this.playing,
    required this.members,
    this.started = true,
  });
  final String id, videoId, title, hostId, hostName, control;
  final bool playing;

  /// false = vestíbulo: sentados esperando a que quien creó la sala pulse "Comenzar".
  final bool started;
  final List<PartyMember> members;

  factory PartyInfo.fromJson(Map<String, dynamic> j) => PartyInfo(
        id: '${j['room']}',
        videoId: '${j['videoId']}',
        title: '${j['title'] ?? ''}',
        hostId: '${j['host']}',
        hostName: '${j['hostName'] ?? ''}',
        control: '${j['control'] ?? 'all'}',
        playing: j['playing'] == true,
        started: j['started'] != false,
        members: [
          for (final m in (j['members'] as List? ?? const []))
            if (m is Map) PartyMember.fromJson(m.cast<String, dynamic>())
        ],
      );
}

class RemoteState {
  const RemoteState(
      {this.connected = false,
      this.tried = false,
      this.myId,
      this.devices = const [],
      this.parties = const []});
  final bool connected;
  final bool tried; // ya se intentó conectar al menos una vez
  final String? myId;
  final List<RemoteDevice> devices;

  /// Salas de "ver juntos" abiertas ahora mismo en el servidor.
  final List<PartyInfo> parties;
  List<RemoteDevice> get others => devices.where((d) => d.id != myId).toList();
  RemoteState copyWith(
          {bool? connected,
          String? myId,
          List<RemoteDevice>? devices,
          List<PartyInfo>? parties}) =>
      RemoteState(
          connected: connected ?? this.connected,
          tried: tried,
          myId: myId ?? this.myId,
          devices: devices ?? this.devices,
          parties: parties ?? this.parties);
}

/// Conexión WebSocket con el servidor: dispositivos, órdenes y avisos de biblioteca.
/// Se reconecta sola y se reinicia cuando cambia la sesión.
class RemoteNotifier extends Notifier<RemoteState> {
  WebSocketChannel? _ch;
  Timer? _retry;
  int _gen = 0; // invalida conexiones de una sesión anterior
  bool _wasLost = false;
  final _cmds = StreamController<Map<String, dynamic>>.broadcast();
  // Mensajes de "ver juntos" (estado de la sala, invitaciones...).
  final _party = StreamController<Map<String, dynamic>>.broadcast();
  // Mensajes del chat de voz del vestíbulo (a quién llamar, señales de conexión).
  final _voice = StreamController<Map<String, dynamic>>.broadcast();
  // Diferencia entre el reloj del servidor y el de este dispositivo, para sincronizar.
  int _clockOffset = 0;
  int _bestRtt = 1 << 30;
  Timer? _pingTimer;
  int _failures = 0; // intentos seguidos de conectar sin éxito

  Stream<Map<String, dynamic>> get commands => _cmds.stream;
  Stream<Map<String, dynamic>> get partyMessages => _party.stream;
  Stream<Map<String, dynamic>> get voiceMessages => _voice.stream;

  /// Hora del servidor ahora mismo (ms desde 1970).
  int serverNow() => DateTime.now().millisecondsSinceEpoch + _clockOffset;

  void _sendWho(UserProfile? p) => send({
        'type': 'who',
        'profile': p == null
            ? null
            : {'username': p.username, 'avatar': p.avatar, 'avatarV': p.avatarV},
      });

  void _ping() => send({'type': 'ping', 't0': DateTime.now().millisecondsSinceEpoch});

  void _onPong(Map<String, dynamic> m) {
    final t1 = DateTime.now().millisecondsSinceEpoch;
    final t0 = (m['t0'] as num?)?.toInt();
    final ts = (m['ts'] as num?)?.toInt();
    if (t0 == null || ts == null) return;
    final rtt = t1 - t0;
    if (rtt < 0) return;
    // Se queda con la muestra de menor latencia (la más fiable); el tope sube un poco en cada
    // ping para ir admitiendo muestras nuevas si los relojes se desfasan.
    if (rtt <= _bestRtt) {
      _bestRtt = rtt;
      _clockOffset = ts + rtt ~/ 2 - t1;
    }
    _bestRtt += 5;
  }

  @override
  RemoteState build() {
    final s = ref.watch(sessionProvider);
    final gen = ++_gen;
    // Con qué perfil está este dispositivo: otros lo ven (foto y nombre) al sentarse en una sala.
    ref.listen(profilesProvider.select((p) => p.valueOrNull?.currentProfile),
        (_, p) => _sendWho(p));
    ref.onDispose(() {
      _gen++;
      _retry?.cancel();
      _pingTimer?.cancel();
      _ch?.sink.close();
      _ch = null;
      if (ref.read(sessionProvider) == null) NativeBridge.stopKeepAlive();
    });
    if (s != null) {
      Future.microtask(() => _connect(s, gen));
      NativeBridge.startKeepAlive();
    }
    return const RemoteState();
  }

  String get _deviceName => deviceName(ref.read(prefsProvider));

  Future<void> _connect(Session s, int gen) async {
    if (gen != _gen) return;
    WebSocketChannel? ch;
    try {
      final base = s.host.startsWith('http') ? s.host : 'http://${s.host}';
      final uri = Uri.parse(
          '${base.replaceFirst('http', 'ws')}/ws?token=${Uri.encodeQueryComponent(s.token)}');
      ch = WebSocketChannel.connect(uri);
      await ch.ready.timeout(const Duration(seconds: 4));
      // Versión del cliente instalada: el servidor la muestra junto al dispositivo.
      final ver = await NativeBridge.appVersion();
      if (gen != _gen) {
        ch.sink.close();
        return;
      }
      _ch = ch;
      _failures = 0;
      final back = _wasLost;
      _wasLost = false;
      state = const RemoteState(connected: true, tried: true);
      if (back) {
        // El servidor volvió: recarga lo que falló mientras estaba apagado.
        ref.invalidate(libraryProvider);
        ref.invalidate(serverInfoProvider);
        ref.invalidate(profilesProvider);
      }
      send({
        'type': 'hello',
        'name': _deviceName,
        if (ver != null) 'version': ver.name,
        if (ver != null) 'code': ver.code,
      });
      _sendWho(ref.read(profilesProvider).valueOrNull?.currentProfile);
      // Reloj del servidor: varias muestras al conectar y una cada 20 s.
      _bestRtt = 1 << 30;
      _pingTimer?.cancel();
      _ping();
      Future<void>.delayed(const Duration(milliseconds: 300), _ping);
      Future<void>.delayed(const Duration(milliseconds: 900), _ping);
      _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) => _ping());
      Future.microtask(() => ref.read(tmdbCredsProvider.notifier).sync());
      // Al conectar (y cada vez que el servidor avisa) se comprueba si hay versión nueva.
      Future.microtask(() => ref.read(updaterProvider.notifier).check());
      ch.stream.listen(
        (raw) {
          if (gen == _gen) _handle(jsonDecode(raw as String) as Map<String, dynamic>);
        },
        onDone: () => _lost(s, gen),
        onError: (_) => _lost(s, gen),
      );
    } catch (_) {
      ch?.sink.close();
      _lost(s, gen);
    }
  }

  /// El servidor dejó de responder en su dirección: lo busca por la red (nombre y puerto salen
  /// de la respuesta) y, si lo encuentra en otra dirección, se reconecta ahí con el mismo token.
  Future<void> _relocate(Session s, int gen) async {
    try {
      final list = await discoverServers();
      if (gen != _gen) return;
      for (final f in list) {
        if (f.info.name == s.name && f.address != s.host) {
          await ref
              .read(sessionProvider.notifier)
              .save(Session(f.address, s.name, s.token));
          return;
        }
      }
    } catch (_) {}
  }

  void _lost(Session s, int gen) {
    if (gen != _gen) return;
    _ch = null;
    _pingTimer?.cancel();
    _wasLost = true;
    // Si no vuelve a la primera, quizá el servidor cambió de IP: se busca de nuevo en la red.
    _failures++;
    if (_failures == 3 || (_failures > 3 && _failures % 10 == 0)) _relocate(s, gen);
    state = const RemoteState(tried: true);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), () => _connect(s, gen));
  }

  void _handle(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'welcome':
        state = state.copyWith(myId: m['id'] as String);
      case 'devices':
        state = state.copyWith(devices: [
          for (final d in m['devices'] as List) RemoteDevice.fromJson(d as Map<String, dynamic>)
        ]);
      case 'library':
        ref.invalidate(libraryProvider);
      case 'update':
        // El dueño dejó, cambió o quitó el APK en el servidor.
        ref.read(updaterProvider.notifier).check();
      case 'profiles':
        // Otro dispositivo creó, cambió o borró un perfil.
        ref.invalidate(profilesProvider);
      case 'command':
        _cmds.add(m);
      case 'party_state' || 'party_invite' || 'party_end':
        _party.add(m);
      case 'voice_peers' || 'voice_signal':
        _voice.add(m);
      case 'pong':
        _onPong(m);
      case 'parties':
        state = state.copyWith(parties: [
          for (final p in m['parties'] as List)
            if (p is Map) PartyInfo.fromJson(p.cast<String, dynamic>())
        ]);
    }
  }

  void send(Map<String, dynamic> m) {
    try {
      _ch?.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  /// Publica lo que se está reproduciendo (null al salir del reproductor).
  void publishState(Map<String, dynamic>? s) => send({'type': 'state', 'state': s});

  void command(String to, String action, [Map<String, dynamic> extra = const {}]) =>
      send({'type': 'command', 'to': to, 'action': action, ...extra});
}

final remoteProvider = NotifierProvider<RemoteNotifier, RemoteState>(RemoteNotifier.new);

final commandsProvider = StreamProvider<Map<String, dynamic>>(
    (ref) => ref.watch(remoteProvider.notifier).commands);

/// true cuando el servidor no responde (se intentó conectar y falló).
final serverOfflineProvider = Provider<bool>((ref) {
  final r = ref.watch(remoteProvider);
  return r.tried && !r.connected;
});
