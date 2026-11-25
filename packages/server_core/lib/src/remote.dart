import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'auth.dart';

class _Peer {
  _Peer(this.id, this.channel, this.token);
  final String id;
  final WebSocketChannel channel;

  /// Token con el que se conectó (identifica al dispositivo emparejado).
  final String? token;

  /// Nombre que el propio dispositivo dijo en su "hello".
  String helloName = 'Dispositivo';
  Map<String, dynamic>? state; // lo que está reproduciendo, o null

  /// Perfil de usuario activo en ese dispositivo (nombre y foto), o null.
  Map<String, dynamic>? profile;
}

/// Sala de "ver juntos": todos los miembros reproducen el mismo video sincronizados.
/// El estado es una posición ([posMs]) medida a una hora del servidor ([at]); si se está
/// reproduciendo, la posición actual es `posMs + (ahora - at)`.
class _Party {
  _Party(this.id, this.hostId, this.videoId, this.title, this.control);
  final String id;
  String hostId; // quien creó la sala (o quien lo heredó al salir)
  String videoId, title;
  String control; // 'all' = todos controlan; 'host' = solo hostId
  final members = <String>[]; // ids de dispositivo, en orden de entrada
  final buffering = <String, int>{}; // dispositivo -> desde cuándo carga (ms)
  bool userPlaying = true; // lo que pidieron las personas
  bool playing = true; // lo efectivo: pide reproducir Y nadie está cargando
  // false = vestíbulo: todos sentados esperando a que quien creó la sala pulse "Comenzar".
  bool started = true;
  // Al comenzar: quienes aún no abrieron el reproductor. Pasado un rato sin llegar, se sacan.
  final pending = <String>{};
  int startAt = 0;
  // Chat de voz del vestíbulo: quiénes lo tienen activado y quiénes tienen el micrófono en silencio.
  final voice = <String>{};
  final muted = <String>{};
  int posMs = 0, at = 0, epoch = 0, seq = 0;
}

/// Hub WebSocket: lista los dispositivos conectados con su estado de reproducción,
/// reenvía órdenes de control remoto y avisa de cambios en la biblioteca.
class RemoteHub {
  final _peers = <String, _Peer>{};
  final _parties = <String, _Party>{};
  Timer? _partyTimer;
  int _pn = 0;
  final _changes = StreamController<void>.broadcast();
  int _n = 0;

  /// Nombre que el dueño del servidor le puso al dispositivo con ese token (o null).
  /// Si existe, manda sobre el que el dispositivo dice de sí mismo.
  String? Function(String token)? aliasOf;

  /// Se llama cuando un dispositivo con token dice su nombre ("hello"); sirve para
  /// actualizar el nombre de dispositivos emparejados con un nombre antiguo.
  void Function(String token, String name)? onHello;

  /// Se llama cuando un dispositivo dice qué versión del cliente tiene (en su "hello").
  void Function(String token, String? version, int? code)? onVersion;

  /// Se llama cuando un dispositivo con token se conecta o se desconecta.
  void Function(String token)? onPresence;

  Stream<void> get changes => _changes.stream;
  List<String> get names => _peers.values.map(_name).toList();

  /// Tokens de los dispositivos que tienen ahora mismo el WebSocket abierto.
  Set<String> get connectedTokens => {
        for (final d in _peers.values)
          if (d.token != null) d.token!
      };

  String _name(_Peer d) {
    final t = d.token;
    return (t == null ? null : aliasOf?.call(t)) ?? d.helloName;
  }

  /// Handler de `/ws`. El token ya lo validó el middleware de [Auth].
  /// Con `pingInterval`, una conexión que se cae sin cerrarse (el móvil pierde el
  /// Wi-Fi) se detecta en unos segundos en vez de quedar "conectada" para siempre.
  Handler get handler => (Request req) {
        final token = requestToken(req);
        return webSocketHandler(
          (WebSocketChannel ch, String? protocol) => _connect(ch, token),
          pingInterval: const Duration(seconds: 15),
        )(req);
      };

  void _connect(WebSocketChannel ch, String? token) {
    final me = _Peer('d${++_n}', ch, token);
    _peers[me.id] = me;
    _send(me, {'type': 'welcome', 'id': me.id});
    if (token != null) onPresence?.call(token);
    _changes.add(null); // ya cuenta como conectado (la lista a los clientes sale con su "hello")
    ch.stream.listen(
      (raw) {
        try {
          _onMessage(me, jsonDecode(raw as String) as Map<String, dynamic>);
        } catch (_) {}
      },
      onDone: () => _drop(me),
      onError: (_) => _drop(me),
    );
  }

  void _drop(_Peer d) {
    if (_peers.remove(d.id) != null) {
      _partyLeaveAll(d);
      final t = d.token;
      if (t != null) onPresence?.call(t);
      _broadcastDevices();
    }
  }

  /// Corta las conexiones de un dispositivo (p. ej. al revocar su emparejamiento).
  void dropToken(String token) {
    final mine = _peers.values.where((d) => d.token == token).toList();
    for (final d in mine) {
      _peers.remove(d.id);
      _partyLeaveAll(d);
      try {
        d.channel.sink.close();
      } catch (_) {}
    }
    if (mine.isNotEmpty) _broadcastDevices();
  }

  /// Vuelve a enviar la lista de dispositivos (tras cambiar un nombre).
  void refresh() => _broadcastDevices();

  void _onMessage(_Peer me, Map<String, dynamic> m) {
    switch (m['type']) {
      case 'hello':
        me.helloName = (m['name'] ?? 'Dispositivo').toString();
        final tk = me.token;
        if (tk != null && m['name'] != null) onHello?.call(tk, me.helloName);
        if (tk != null && m['version'] != null) {
          onVersion?.call(tk, '${m['version']}', (m['code'] as num?)?.toInt());
        }
        _broadcastDevices();
        _sendParties(me);
      case 'who':
        // El dispositivo dice con qué perfil de usuario está (para su foto en la sala).
        final pr = m['profile'];
        me.profile = pr is Map
            ? {'username': '${pr['username']}', 'avatar': pr['avatar'], 'avatarV': pr['avatarV']}
            : null;
        _broadcastDevices();
        _broadcastParties();
      case 'state':
        me.state = (m['state'] as Map?)?.cast<String, dynamic>();
        _broadcastDevices();
      case 'command':
        final target = _peers[m['to']];
        if (target != null) _send(target, {...m, 'from': me.id, 'fromName': _name(me)});
      case 'ping':
        // Para que los clientes calculen la diferencia entre su reloj y el del servidor.
        _send(me, {'type': 'pong', 't0': m['t0'], 'ts': _now});
      case 'party_create':
        _partyCreate(me, m);
      case 'party_invite':
        _partyInvite(me, m);
      case 'party_join':
        _partyJoin(me, m);
      case 'party_leave':
        _partyLeave(me, '${m['room']}');
      case 'party_ctl':
        _partyCtl(me, m);
      case 'party_buf':
        _partyBuf(me, m);
      case 'party_set':
        _partySet(me, m);
      case 'party_start':
        _partyStart(me, m);
      case 'voice_join':
        _voiceJoin(me, m);
      case 'voice_leave':
        _voiceLeave(me, '${m['room']}');
      case 'voice_mute':
        _voiceMute(me, m);
      case 'voice_signal':
        _voiceSignal(me, m);
    }
  }

  void _broadcastDevices() {
    final list = [
      for (final d in _peers.values)
        {'id': d.id, 'name': _name(d), 'state': d.state, if (d.profile != null) 'profile': d.profile}
    ];
    for (final d in _peers.values) {
      _send(d, {'type': 'devices', 'devices': list});
    }
    _changes.add(null);
  }

  /// Avisa a los clientes de que cambió la lista de perfiles de usuario.
  void notifyProfiles() {
    for (final d in _peers.values) {
      _send(d, {'type': 'profiles'});
    }
  }

  void notifyLibrary() {
    for (final d in _peers.values) {
      _send(d, {'type': 'library'});
    }
  }

  /// Avisa a los clientes de que cambió el APK de actualización.
  void notifyUpdate() {
    for (final d in _peers.values) {
      _send(d, {'type': 'update'});
    }
  }

  // ================= ver juntos =================

  int get _now => DateTime.now().millisecondsSinceEpoch;

  int _expected(_Party p, int now) => p.playing ? p.posMs + (now - p.at) : p.posMs;

  String _nameOf(String id) {
    final d = _peers[id];
    return d == null ? '' : _name(d);
  }

  /// Fija el estado de la sala y avisa a todos. [pos] = posición nueva (si no, la que
  /// toca ahora). Reproduce solo si alguien lo pidió y nadie está cargando.
  void _recompute(_Party p, {int? pos, String? by}) {
    final now = _now;
    final v = pos ?? _expected(p, now);
    p.posMs = v < 0 ? 0 : v;
    p.playing = p.started && p.userPlaying && p.buffering.isEmpty;
    p.at = now;
    p.seq++;
    _partyBroadcast(p, by: by);
  }

  Map<String, dynamic> _partyJson(_Party p, {String? by}) => {
        'type': 'party_state',
        'room': p.id,
        'host': p.hostId,
        'hostName': _nameOf(p.hostId),
        'control': p.control,
        'videoId': p.videoId,
        'title': p.title,
        'playing': p.playing,
        'started': p.started,
        'posMs': p.posMs,
        'at': p.at,
        'epoch': p.epoch,
        'seq': p.seq,
        if (by != null) 'by': by,
        'members': [
          for (final id in p.members)
            if (_peers[id] != null)
              {
                'id': id,
                'name': _nameOf(id),
                'buffering': p.buffering.containsKey(id),
                'voice': p.voice.contains(id),
                if (p.muted.contains(id)) 'muted': true,
                if (_peers[id]!.profile != null) 'profile': _peers[id]!.profile,
              }
        ],
      };

  void _partyBroadcast(_Party p, {String? by}) {
    final msg = _partyJson(p, by: by);
    for (final id in p.members) {
      final d = _peers[id];
      if (d != null) _send(d, msg);
    }
    _broadcastParties();
  }

  Map<String, dynamic> get _partiesMsg =>
      {'type': 'parties', 'parties': [for (final p in _parties.values) _partyJson(p)]};

  /// Todas las salas abiertas, a todos los dispositivos (para la pestaña "Sala").
  void _broadcastParties() {
    final msg = _partiesMsg;
    for (final d in _peers.values) {
      _send(d, msg);
    }
  }

  void _sendParties(_Peer d) => _send(d, _partiesMsg);

  _Party? _memberParty(_Peer me, Object? room) {
    final p = _parties['$room'];
    return (p != null && p.members.contains(me.id)) ? p : null;
  }

  void _partyCreate(_Peer me, Map<String, dynamic> m) {
    final video = '${m['videoId'] ?? ''}';
    if (video.isEmpty || video == 'null') return;
    _partyLeaveAll(me);
    final p = _Party('p${++_pn}', me.id, video, '${m['title'] ?? ''}',
        m['control'] == 'host' ? 'host' : 'all');
    p.members.add(me.id);
    // Con `lobby` la sala empieza en el vestíbulo: sin reproducir hasta que se pulse "Comenzar".
    final lobby = m['lobby'] == true;
    p.started = !lobby;
    p.userPlaying = !lobby && m['playing'] != false;
    p.playing = p.started && p.userPlaying;
    p.posMs = (m['posMs'] as num?)?.toInt() ?? 0;
    p.at = _now;
    _parties[p.id] = p;
    _partyTimer ??= Timer.periodic(const Duration(seconds: 3), (_) => _partySweep());
    _partyBroadcast(p, by: me.id);
  }

  void _partyInvite(_Peer me, Map<String, dynamic> m) {
    final p = _memberParty(me, m['room']);
    final target = _peers['${m['to']}'];
    if (p == null || target == null || p.members.contains(target.id)) return;
    _send(target, {
      'type': 'party_invite',
      'room': p.id,
      'videoId': p.videoId,
      'title': p.title,
      'from': me.id,
      'fromName': _name(me),
    });
  }

  void _partyJoin(_Peer me, Map<String, dynamic> m) {
    final p = _parties['${m['room']}'];
    if (p == null) {
      _send(me, {
        'type': 'party_end',
        'room': '${m['room']}',
        'reason': 'La sala ya no existe.'
      });
      return;
    }
    if (!p.members.contains(me.id)) {
      _partyLeaveAll(me);
      p.members.add(me.id);
    }
    p.pending.remove(me.id); // ya llegó al reproductor
    // Mientras abre el video, la sala espera por quien entra (en el vestíbulo no hay video).
    if (p.started) p.buffering[me.id] = _now;
    _recompute(p, by: me.id);
  }

  void _partyLeave(_Peer me, String room) => _partyRemove(room, me.id);

  /// Saca a [id] de la sala. Devuelve false si la sala dejó de existir.
  bool _partyRemove(String room, String id, {bool notify = true}) {
    final p = _parties[room];
    if (p == null) return false;
    if (!p.members.remove(id)) return true;
    p.buffering.remove(id);
    p.pending.remove(id);
    p.voice.remove(id);
    p.muted.remove(id);
    if (p.members.isEmpty) {
      _parties.remove(room);
      _broadcastParties();
      return false;
    }
    if (p.hostId == id) p.hostId = p.members.first;
    if (notify) _recompute(p); // el resto sigue; quizá esperaban a quien se fue
    return true;
  }

  /// Quien creó la sala pulsa "Comenzar": todos pasan al reproductor y arrancan a la vez.
  void _partyStart(_Peer me, Map<String, dynamic> m) {
    final p = _memberParty(me, m['room']);
    if (p == null || p.started || me.id != p.hostId) return;
    p.started = true;
    p.userPlaying = true;
    // El chat de voz es del vestíbulo: al empezar la función se corta para todos.
    p.voice.clear();
    p.muted.clear();
    final now = _now;
    p.startAt = now;
    p.pending
      ..clear()
      ..addAll(p.members);
    // La sala espera a que cada uno abra el video. La marca nace "vieja" para que quien no
    // llegue (móvil dormido) deje de bloquear a los demás a los ~12 s en vez de a los 25 s.
    for (final id in p.members) {
      p.buffering[id] = now - 13000;
    }
    _recompute(p, pos: p.posMs, by: me.id);
  }

  // ================= chat de voz del vestíbulo =================
  // El audio va directo entre dispositivos (WebRTC); el servidor solo guarda quién está en el
  // chat de voz y reenvía las señales de conexión (ofertas, respuestas y candidatos ICE).

  /// Alguien activa el chat de voz. Se le dice a quién debe llamar (los que ya estaban): el
  /// último en entrar siempre es quien llama, así dos personas nunca se llaman a la vez.
  void _voiceJoin(_Peer me, Map<String, dynamic> m) {
    final p = _memberParty(me, m['room']);
    if (p == null || p.started) return; // solo en el vestíbulo
    final others = [
      for (final id in p.voice)
        if (id != me.id && _peers[id] != null) id
    ];
    p.voice.add(me.id);
    p.muted.remove(me.id);
    _send(me, {'type': 'voice_peers', 'room': p.id, 'peers': others});
    _partyBroadcast(p);
  }

  void _voiceLeave(_Peer me, String room) {
    final p = _memberParty(me, room);
    if (p == null) return;
    final was = p.voice.remove(me.id);
    p.muted.remove(me.id);
    if (was) _partyBroadcast(p);
  }

  void _voiceMute(_Peer me, Map<String, dynamic> m) {
    final p = _memberParty(me, m['room']);
    if (p == null || !p.voice.contains(me.id)) return;
    final mute = m['muted'] == true;
    if (mute == p.muted.contains(me.id)) return;
    if (mute) {
      p.muted.add(me.id);
    } else {
      p.muted.remove(me.id);
    }
    _partyBroadcast(p);
  }

  /// Reenvía una señal de conexión de un dispositivo a otro de la misma sala.
  void _voiceSignal(_Peer me, Map<String, dynamic> m) {
    final p = _memberParty(me, m['room']);
    final to = _peers['${m['to']}'];
    if (p == null || to == null) return;
    if (!p.voice.contains(me.id) || !p.voice.contains(to.id)) return;
    _send(to, {'type': 'voice_signal', 'room': p.id, 'from': me.id, 'data': m['data']});
  }

  void _partyLeaveAll(_Peer me) {
    for (final p in _parties.values.toList()) {
      if (p.members.contains(me.id)) _partyLeave(me, p.id);
    }
  }

  void _partyCtl(_Peer me, Map<String, dynamic> m) {
    final p = _memberParty(me, m['room']);
    if (p == null || !p.started) return; // en el vestíbulo aún no hay nada que controlar
    if (p.control == 'host' && me.id != p.hostId) {
      // No puede controlar: se le devuelve el estado de la sala para que se reajuste.
      _send(me, {..._partyJson(p), 'denied': true});
      return;
    }
    final pos = (m['posMs'] as num?)?.toInt();
    switch (m['action']) {
      case 'play':
        p.userPlaying = true;
        _recompute(p, pos: pos, by: me.id);
      case 'pause':
        p.userPlaying = false;
        _recompute(p, pos: pos, by: me.id);
      case 'seek':
        _recompute(p, pos: pos, by: me.id);
      case 'next':
        final id = '${m['videoId'] ?? ''}';
        if (id.isEmpty || id == 'null') return;
        p.videoId = id;
        p.title = '${m['title'] ?? ''}';
        p.epoch++;
        p.userPlaying = true;
        // Todos van a abrir el nuevo video: la sala espera a que cada uno esté listo.
        final now = _now;
        for (final mid in p.members) {
          p.buffering[mid] = now;
        }
        _recompute(p, pos: 0, by: me.id);
    }
  }

  void _partyBuf(_Peer me, Map<String, dynamic> m) {
    final p = _memberParty(me, m['room']);
    if (p == null) return;
    final b = m['buffering'] == true;
    if (b == p.buffering.containsKey(me.id)) return;
    if (b) {
      p.buffering[me.id] = _now;
    } else {
      p.buffering.remove(me.id);
    }
    _recompute(p);
  }

  void _partySet(_Peer me, Map<String, dynamic> m) {
    final p = _memberParty(me, m['room']);
    if (p == null || me.id != p.hostId) return; // solo quien creó la sala
    p.control = m['control'] == 'host' ? 'host' : 'all';
    _recompute(p, by: me.id);
  }

  /// Quien lleva más de 25 s "cargando" deja de bloquear a la sala (se colgó o se fue).
  void _partySweep() {
    if (_parties.isEmpty) {
      _partyTimer?.cancel();
      _partyTimer = null;
      return;
    }
    final now = _now;
    for (final p in _parties.values.toList()) {
      // Quien no abrió el reproductor a los 30 s de comenzar se saca de la sala.
      if (p.pending.isNotEmpty && now - p.startAt > 30000) {
        final gone = p.pending.toList();
        p.pending.clear();
        var alive = true;
        for (final id in gone) {
          alive = _partyRemove(p.id, id, notify: false);
          if (!alive) break;
        }
        if (!alive) continue;
        _recompute(p);
      }
      final stale = [
        for (final e in p.buffering.entries)
          if (now - e.value > 25000) e.key
      ];
      if (stale.isEmpty) continue;
      for (final id in stale) {
        p.buffering.remove(id);
      }
      _recompute(p);
    }
  }

  void _send(_Peer d, Map<String, dynamic> m) {
    try {
      d.channel.sink.add(jsonEncode(m));
    } catch (_) {}
  }

  void closeAll() {
    _partyTimer?.cancel();
    _partyTimer = null;
    _parties.clear();
    for (final d in _peers.values.toList()) {
      try {
        d.channel.sink.close();
      } catch (_) {}
    }
    _peers.clear();
  }
}
