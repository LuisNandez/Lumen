import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'remote.dart';

// ===========================================================================
//  Chat de voz del vestíbulo ("Sala"): mientras la función aún no empieza, quienes están
//  sentados pueden hablar entre sí. El audio va DIRECTO entre dispositivos (WebRTC, malla
//  completa: pensado para pocas personas en la misma red); el servidor solo anota quién está
//  en el chat y reenvía las señales de conexión por el WebSocket que ya existe.
//
//  Quién habla se mide en cada dispositivo con las estadísticas de WebRTC (nivel del audio
//  recibido de cada persona y del micrófono propio) y se refleja en las butacas.
//  Al comenzar la función el chat de voz se corta solo (lo decide el servidor).
// ===========================================================================

class VoiceState {
  const VoiceState({
    this.active = false,
    this.connecting = false,
    this.muted = false,
    this.listenOnly = false,
    this.speaker = true,
    this.speaking = const {},
    this.error,
  });

  /// Chat de voz activado (ya se unió).
  final bool active;

  /// Pidiendo el micrófono / esperando al servidor.
  final bool connecting;

  /// Mi micrófono está en silencio.
  final bool muted;

  /// Sin micrófono (una TV, o permiso denegado): se escucha a los demás, pero no se habla.
  final bool listenOnly;

  /// Salida por el altavoz (si no, auricular o lo que haya conectado).
  final bool speaker;

  /// Ids de dispositivo de quienes están hablando ahora (incluido el mío).
  final Set<String> speaking;
  final String? error;

  VoiceState copyWith({
    bool? active,
    bool? connecting,
    bool? muted,
    bool? listenOnly,
    bool? speaker,
    Set<String>? speaking,
    String? error,
    bool clearError = false,
  }) =>
      VoiceState(
        active: active ?? this.active,
        connecting: connecting ?? this.connecting,
        muted: muted ?? this.muted,
        listenOnly: listenOnly ?? this.listenOnly,
        speaker: speaker ?? this.speaker,
        speaking: speaking ?? this.speaking,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Conexión de audio con otra persona de la sala.
class _VoicePeer {
  _VoicePeer(this.id, this.pc);
  final String id;
  final rtc.RTCPeerConnection pc;
  final pending = <rtc.RTCIceCandidate>[]; // candidatos que llegaron antes de la respuesta
  bool hasRemote = false;
  bool closed = false;
  bool initiator = false; // yo la llamé
  int retries = 0;
}

class VoiceNotifier extends Notifier<VoiceState> {
  late RemoteNotifier _rn;
  rtc.MediaStream? _local;
  final _peers = <String, _VoicePeer>{};
  String? _room;
  int _gen = 0; // invalida tareas pendientes al parar
  bool _disposed = false;
  Timer? _statsTimer, _joinTimeout;
  bool _polling = false;
  // Los mensajes de voz se procesan de uno en uno (cada uno puede tardar).
  Future<void> _queue = Future<void>.value();

  final _lastLoud = <String, int>{};
  final _energy = <String, (double, double)>{};

  /// Por encima de este nivel (0..1) se considera que alguien habla, y se mantiene un
  /// instante para que el indicador no parpadee entre sílabas.
  static const _threshold = 0.02;
  static const _holdMs = 450;

  @override
  VoiceState build() {
    _rn = ref.read(remoteProvider.notifier);
    final sub = _rn.voiceMessages.listen((m) {
      _queue = _queue.then((_) => _onMsg(m)).catchError((_) {});
    });
    ref.listen<RemoteState>(remoteProvider, (_, next) => _checkRoom(next));
    ref.onDispose(() {
      _disposed = true;
      sub.cancel();
      _teardown(send: false);
    });
    return const VoiceState();
  }

  void _set(VoiceState Function(VoiceState s) f) {
    if (!_disposed) state = f(state);
  }

  PartyInfo? _myParty(RemoteState r) {
    final id = r.myId;
    if (id == null) return null;
    for (final p in r.parties) {
      if (p.members.any((m) => m.id == id)) return p;
    }
    return null;
  }

  /// La sala cambió: si ya no estoy en ella o la función empezó, se corta el chat de voz;
  /// y se cierra el audio con quien ya salió del chat.
  void _checkRoom(RemoteState r) {
    final room = _room;
    if (room == null) return;
    final p = _myParty(r);
    if (p == null || p.id != room || p.started) {
      stop();
      return;
    }
    final inVoice = {
      for (final m in p.members)
        if (m.voice) m.id
    };
    for (final id in _peers.keys.toList()) {
      if (!inVoice.contains(id)) _dropPeer(id);
    }
  }

  // ======== acciones de la persona ========

  /// Activa el chat de voz: pide el micrófono y se une a quienes ya estén hablando.
  Future<void> start() async {
    if (state.active || state.connecting) return;
    final p = _myParty(ref.read(remoteProvider));
    if (p == null || p.started) return;
    final gen = ++_gen;
    _set((s) => s.copyWith(connecting: true, clearError: true));
    rtc.MediaStream? stream;
    try {
      stream = await rtc.navigator.mediaDevices.getUserMedia({
        'audio': {
          // Estándar...
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
          'channelCount': 1,
          'sampleRate': 48000,
          // ...y los equivalentes de libwebrtc (Android/iOS): eco, ruido de fondo, ruido de
          // teclas/golpes, filtro de graves (ventiladores, viento, golpes en la mesa) y volumen.
          'optional': [
            {'googEchoCancellation': true},
            {'googEchoCancellation2': true},
            {'googNoiseSuppression': true},
            {'googNoiseSuppression2': true},
            {'googAutoGainControl': true},
            {'googAutoGainControl2': true},
            {'googHighpassFilter': true},
            {'googTypingNoiseDetection': true},
          ],
        },
        'video': false,
      });
    } catch (_) {
      // Sin micrófono (TV, o permiso denegado): se entra solo para escuchar.
      stream = null;
    }
    if (gen != _gen || _disposed) {
      if (stream != null) _stopStream(stream);
      return;
    }
    final listen = stream == null;
    _local = stream;
    _room = p.id;
    _set((s) => s.copyWith(muted: listen, listenOnly: listen));
    _applySpeaker();
    _rn.send({'type': 'voice_join', 'room': p.id});
    // Quien solo escucha figura con el micrófono en silencio (insignia roja en su butaca).
    if (listen) _rn.send({'type': 'voice_mute', 'room': p.id, 'muted': true});
    // Un servidor antiguo no entiende el chat de voz y nunca responde.
    _joinTimeout?.cancel();
    _joinTimeout = Timer(const Duration(seconds: 5), () {
      if (state.connecting && gen == _gen) {
        stop();
        _set((s) => s.copyWith(
            error: 'El servidor no admite el chat de voz. Actualiza el servidor.'));
      }
    });
  }

  /// Desactiva el chat de voz y suelta el micrófono.
  void stop() {
    _teardown();
    _set((s) => VoiceState(speaker: s.speaker));
  }

  void toggleMute() {
    final local = _local;
    if (local == null || !state.active) return;
    final mute = !state.muted;
    for (final t in local.getAudioTracks()) {
      t.enabled = !mute;
    }
    _set((s) => s.copyWith(muted: mute));
    _rn.send({'type': 'voice_mute', 'room': _room, 'muted': mute});
  }

  void toggleSpeaker() {
    _set((s) => s.copyWith(speaker: !s.speaker));
    _applySpeaker();
  }

  Future<void> _applySpeaker() async {
    try {
      await rtc.Helper.setSpeakerphoneOn(state.speaker);
    } catch (_) {}
  }

  // ======== mensajes del servidor ========

  Future<void> _onMsg(Map<String, dynamic> m) async {
    final room = _room;
    if (room == null || '${m['room']}' != room || _disposed) return;
    final gen = _gen;
    switch (m['type']) {
      case 'voice_peers':
        _joinTimeout?.cancel();
        _set((s) => s.copyWith(active: true, connecting: false));
        _applySpeaker();
        _startStats();
        // Quien entra llama a los que ya estaban.
        for (final id in (m['peers'] as List? ?? const [])) {
          if (gen != _gen) return;
          try {
            await _call('$id');
          } catch (_) {
            _dropPeer('$id');
          }
        }
      case 'voice_signal':
        try {
          await _onSignal('${m['from']}', m['data'], gen);
        } catch (_) {
          _dropPeer('${m['from']}');
        }
    }
  }

  void _signal(String to, Map<String, dynamic> data) {
    final room = _room;
    if (room == null) return;
    _rn.send({'type': 'voice_signal', 'room': room, 'to': to, 'data': data});
  }

  // ======== conexiones de audio ========

  Future<_VoicePeer> _newPeer(String id) async {
    final local = _local; // null = solo escucha
    final gen = _gen;
    // Sin servidores STUN: es una red local y los candidatos directos bastan.
    final pc = await rtc.createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    if (gen != _gen || _local != local || _disposed) {
      await pc.close();
      throw StateError('cancelado');
    }
    final peer = _VoicePeer(id, pc);
    _peers[id] = peer;
    pc.onIceCandidate = (c) {
      final cand = c.candidate;
      if (peer.closed || cand == null || cand.isEmpty) return;
      _signal(id, {
        'candidate': {
          'candidate': cand,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        }
      });
    };
    pc.onConnectionState = (s) {
      if (peer.closed) return;
      if (s == rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _onPeerFailed(peer);
      }
    };
    if (local != null) {
      for (final t in local.getAudioTracks()) {
        await pc.addTrack(t, local);
      }
    }
    return peer;
  }

  /// Llama a [id] (se le manda una oferta).
  Future<void> _call(String id, {int retries = 0}) async {
    _dropPeer(id);
    final peer = await _newPeer(id);
    peer.initiator = true;
    peer.retries = retries;
    final offer = await peer.pc
        .createOffer({'offerToReceiveAudio': true, 'offerToReceiveVideo': false});
    final tuned = rtc.RTCSessionDescription(_tuneSdp(offer.sdp), offer.type);
    await peer.pc.setLocalDescription(tuned);
    _signal(id, {
      'sdp': {'type': tuned.type, 'sdp': tuned.sdp}
    });
  }

  Future<void> _onSignal(String from, Object? data, int gen) async {
    if (data is! Map || (!state.active && !state.connecting)) return;
    final sdp = data['sdp'];
    final cand = data['candidate'];
    if (sdp is Map) {
      final type = '${sdp['type']}';
      if (type == 'offer') {
        // Una oferta nueva sustituye a cualquier conexión anterior con esa persona.
        _dropPeer(from);
        final peer = await _newPeer(from);
        await peer.pc.setRemoteDescription(rtc.RTCSessionDescription('${sdp['sdp']}', type));
        peer.hasRemote = true;
        await _flush(peer);
        final answer = await peer.pc.createAnswer();
        final tuned = rtc.RTCSessionDescription(_tuneSdp(answer.sdp), answer.type);
        await peer.pc.setLocalDescription(tuned);
        if (gen != _gen) return;
        _signal(from, {
          'sdp': {'type': tuned.type, 'sdp': tuned.sdp}
        });
      } else if (type == 'answer') {
        final peer = _peers[from];
        if (peer == null || peer.closed) return;
        await peer.pc.setRemoteDescription(rtc.RTCSessionDescription('${sdp['sdp']}', type));
        peer.hasRemote = true;
        await _flush(peer);
      }
    } else if (cand is Map) {
      final peer = _peers[from];
      if (peer == null || peer.closed) return;
      final c = rtc.RTCIceCandidate(
          '${cand['candidate']}', cand['sdpMid'] as String?, (cand['sdpMLineIndex'] as num?)?.toInt());
      if (peer.hasRemote) {
        await peer.pc.addCandidate(c);
      } else {
        peer.pending.add(c);
      }
    }
  }

  /// Ajusta Opus para voz por Wi-Fi sin cortes:
  /// - mono (la voz no necesita estéreo) y ~40 kbps: nítido y ligero;
  /// - corrección de pérdidas (FEC): si se pierde algún paquete, se reconstruye;
  /// - sin DTX: no se "apaga" el audio en los silencios (evita que se coman el inicio de las frases);
  /// - paquetes de 20 ms: poca latencia, y se admiten de 10 a 60 ms según la red.
  static String? _tuneSdp(String? sdp) {
    if (sdp == null) return null;
    final eol = sdp.contains('\r\n') ? '\r\n' : '\n';
    final lines = sdp.split(eol);
    final pt = RegExp(r'^a=rtpmap:(\d+) opus/48000').firstMatch(
        lines.firstWhere((l) => l.startsWith('a=rtpmap:') && l.contains(' opus/48000'),
            orElse: () => ''));
    if (pt == null) return sdp;
    final id = pt.group(1)!;
    const params = 'minptime=10;maxptime=60;ptime=20;useinbandfec=1;usedtx=0;cbr=0;'
        'stereo=0;sprop-stereo=0;maxaveragebitrate=40000;maxplaybackrate=48000';
    final fmtp = 'a=fmtp:$id $params';
    final i = lines.indexWhere((l) => l.startsWith('a=fmtp:$id '));
    if (i >= 0) {
      lines[i] = fmtp;
    } else {
      final r = lines.indexWhere((l) => l.startsWith('a=rtpmap:$id '));
      lines.insert(r + 1, fmtp);
    }
    return lines.join(eol);
  }

  Future<void> _flush(_VoicePeer peer) async {
    final list = List<rtc.RTCIceCandidate>.from(peer.pending);
    peer.pending.clear();
    for (final c in list) {
      try {
        await peer.pc.addCandidate(c);
      } catch (_) {}
    }
  }

  /// La conexión falló: quien llamó lo reintenta un par de veces.
  void _onPeerFailed(_VoicePeer peer) {
    final id = peer.id;
    final retry = peer.initiator && peer.retries < 2;
    final next = peer.retries + 1;
    final gen = _gen;
    _dropPeer(id);
    if (!retry) return;
    Future<void>.delayed(const Duration(seconds: 1), () async {
      if (_disposed || gen != _gen || _room == null) return;
      final p = _myParty(ref.read(remoteProvider));
      final still = p != null && p.members.any((m) => m.id == id && m.voice);
      if (!still) return;
      try {
        await _call(id, retries: next);
      } catch (_) {
        _dropPeer(id);
      }
    });
  }

  void _dropPeer(String id) {
    final peer = _peers.remove(id);
    if (peer == null) return;
    peer.closed = true;
    _lastLoud.remove(id);
    _energy.remove('r$id');
    unawaited(() async {
      try {
        await peer.pc.close();
        await peer.pc.dispose();
      } catch (_) {}
    }());
  }

  void _teardown({bool send = true}) {
    _gen++;
    _statsTimer?.cancel();
    _statsTimer = null;
    _joinTimeout?.cancel();
    _joinTimeout = null;
    final room = _room;
    if (send && room != null) _rn.send({'type': 'voice_leave', 'room': room});
    _room = null;
    for (final id in _peers.keys.toList()) {
      _dropPeer(id);
    }
    final local = _local;
    _local = null;
    if (local != null) _stopStream(local);
    _lastLoud.clear();
    _energy.clear();
  }

  void _stopStream(rtc.MediaStream stream) {
    unawaited(() async {
      try {
        for (final t in stream.getTracks()) {
          await t.stop();
        }
        await stream.dispose();
      } catch (_) {}
    }());
  }

  // ======== quién está hablando ========

  void _startStats() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(milliseconds: 300), (_) => _pollStats());
  }

  static double? _num(Object? v) => v == null ? null : double.tryParse('$v');

  /// Nivel de audio (0..1) de una estadística. Se prefiere calcularlo con la energía
  /// acumulada (si no llegan muestras nuevas sale 0) y, si no existe, el nivel directo.
  double? _level(String key, Map<dynamic, dynamic> v) {
    final e = _num(v['totalAudioEnergy']);
    final d = _num(v['totalSamplesDuration']);
    if (e != null && d != null) {
      final prev = _energy[key];
      _energy[key] = (e, d);
      if (prev == null) return 0;
      final dd = d - prev.$2;
      if (dd <= 0) return 0;
      return math.sqrt(math.max(0, (e - prev.$1) / dd));
    }
    return _num(v['audioLevel']);
  }

  Future<void> _pollStats() async {
    if (_polling || _room == null || _disposed) return;
    _polling = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final remoteLevels = <String, double>{};
      double? mine;
      for (final peer in _peers.values.toList()) {
        if (peer.closed) continue;
        List<rtc.StatsReport> reports;
        try {
          reports = await peer.pc.getStats();
        } catch (_) {
          continue;
        }
        for (final r in reports) {
          final v = r.values;
          if ('${v['kind']}' == 'video' || '${v['mediaType']}' == 'video') continue;
          final isTrack = r.type == 'track';
          final remoteSide =
              r.type == 'inbound-rtp' || (isTrack && '${v['remoteSource']}' == 'true');
          final localSide =
              r.type == 'media-source' || (isTrack && '${v['remoteSource']}' == 'false');
          if (!remoteSide && !localSide) continue;
          final lvl = _level(remoteSide ? 'r${peer.id}' : 'local', v);
          if (lvl == null) continue;
          if (remoteSide) {
            remoteLevels[peer.id] = math.max(remoteLevels[peer.id] ?? 0, lvl);
          } else {
            mine = math.max(mine ?? 0, lvl);
          }
        }
      }
      if (_room == null || _disposed) return;
      final speaking = <String>{};
      void mark(String id, double? lvl) {
        if (lvl != null && lvl > _threshold) _lastLoud[id] = now;
        final t = _lastLoud[id];
        if (t != null && now - t < _holdMs) speaking.add(id);
      }

      remoteLevels.forEach(mark);
      final myId = ref.read(remoteProvider).myId;
      if (myId != null && !state.muted) mark(myId, mine);
      if (!setEquals(speaking, state.speaking)) {
        _set((s) => s.copyWith(speaking: speaking));
      }
    } finally {
      _polling = false;
    }
  }
}

final voiceProvider = NotifierProvider<VoiceNotifier, VoiceState>(VoiceNotifier.new);
