import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'cinema.dart';
import 'core.dart';
import 'remote.dart';

/// Cómo se abre el reproductor dentro de una sala: entrando en una que ya existe
/// (viene de una invitación o de la pestaña Sala) o creando una nueva al abrir el video.
class PartyJoin {
  const PartyJoin(String this.room) : createControl = null;
  const PartyJoin.create(String control)
      : room = null,
        createControl = control;
  final String? room;

  /// 'all' o 'host' si hay que crear la sala en cuanto el video esté listo.
  final String? createControl;
}

/// Invitaciones a ver algo juntos que llegan del servidor.
final partyInviteProvider = StreamProvider<Map<String, dynamic>>((ref) => ref
    .watch(remoteProvider.notifier)
    .partyMessages
    .where((m) => m['type'] == 'party_invite'));

int _now() => DateTime.now().millisecondsSinceEpoch;

/// Reproducción conjunta de UN reproductor. El servidor guarda el estado de la sala (si
/// reproduce, en qué posición y a qué hora del servidor se midió); aquí se ve ese estado y se
/// aplica al reproductor, y lo que hace la persona (pausar, saltar) se manda a la sala.
///
/// Sincronía: la posición esperada es `pos + (ahora_servidor - hora)` si se está
/// reproduciendo. Una diferencia pequeña se corrige acelerando o frenando un 5 % (sin saltos);
/// una grande, saltando a la posición esperada.
class PartyController extends ChangeNotifier {
  PartyController({
    required this.player,
    required this.remote,
    required this.myId,
    required this.ready,
    required this.videoId,
    required this.title,
    required this.switchTo,
    required this.toast,
  }) {
    _msgSub = remote.partyMessages.listen(_onMsg);
    _playSub = player.stream.playing.listen(_onPlaying);
    _posSub = player.stream.position.listen(_onPosition);
    _bufSub = player.stream.buffering.listen(_onBuffering);
    _rateSub = player.stream.rate.listen(_onRate);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
  }

  final Player player;
  final RemoteNotifier remote;

  /// Id de este dispositivo en el servidor.
  final String? Function() myId;

  /// El reproductor ya abrió el video y puede reproducir.
  final bool Function() ready;
  final String Function() videoId;
  final String Function() title;

  /// Abre otro video en este reproductor (cuando la sala pasa al capítulo siguiente).
  final Future<void> Function(String id) switchTo;
  final void Function(String text) toast;

  late final StreamSubscription<Map<String, dynamic>> _msgSub;
  late final StreamSubscription<bool> _playSub;
  late final StreamSubscription<Duration> _posSub;
  late final StreamSubscription<bool> _bufSub;
  late final StreamSubscription<double> _rateSub;
  late final Timer _tick;
  Timer? _bufTimer, _awaitTimer;
  bool _disposed = false;

  // ---- estado de la sala ----
  String? room;
  String? hostId, hostName;
  String control = 'all'; // 'all' = todos controlan, 'host' = solo quien la creó
  List<PartyMember> members = const [];
  Map<String, dynamic>? _st; // último estado recibido
  bool _awaiting = false; // se pidió crear una sala y falta la respuesta

  bool get active => room != null;
  bool get isHost => hostId != null && hostId == myId();
  bool get canCreate => !active && !_awaiting && ready();

  // ---- control interno ----
  int _ignoreUntil = 0; // hasta cuándo los cambios del reproductor los causamos nosotros
  int _localAt = 0; // última orden mandada por esta persona
  int _lastPos = 0, _lastPosAt = 0;
  bool _held = false; // todavía no estamos sincronizados (cargando, entrando)
  bool _bufSent = false;
  bool _rateAdj = false;
  bool _switching = false;
  int _syncGen = 0;
  String _lastWaiting = '';

  void _ignoreFor(int ms) {
    final u = _now() + ms;
    if (u > _ignoreUntil) _ignoreUntil = u;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // ======== acciones de la persona ========

  /// Crea una sala con lo que se está viendo ahora.
  void create({required String control}) {
    if (!canCreate) return;
    _awaiting = true;
    _awaitTimer?.cancel();
    _awaitTimer = Timer(const Duration(seconds: 5), () {
      _awaiting = false;
      _changed();
    });
    remote.send({
      'type': 'party_create',
      'videoId': videoId(),
      'title': title(),
      'posMs': player.state.position.inMilliseconds,
      'playing': player.state.playing,
      'control': control,
    });
    _changed();
  }

  String? _createPending;

  /// Crea la sala en cuanto el reproductor tenga el video abierto.
  void createWhenReady(String control) => _createPending = control;

  /// Entra en una sala a la que invitaron. El reproductor aún no está listo: se sincroniza
  /// cuando abra el video (ver [onOpened]); mientras tanto la sala espera.
  void joinRoom(String id) {
    room = id;
    _held = true;
    _bufSent = true; // el servidor ya nos marca como "cargando" al entrar
    remote.send({'type': 'party_join', 'room': id});
    _changed();
  }

  void invite(String deviceId) {
    if (!active) return;
    remote.send({'type': 'party_invite', 'room': room, 'to': deviceId});
  }

  void setControl(String c) {
    if (!active) return;
    remote.send({'type': 'party_set', 'room': room, 'control': c});
  }

  /// "Siguiente episodio" dentro de una sala: lo decide la sala y todos lo abren a la vez.
  void requestNext(String id, String title) {
    if (!active) return;
    _localAt = _now();
    remote.send({
      'type': 'party_ctl',
      'room': room,
      'action': 'next',
      'videoId': id,
      'title': title,
    });
  }

  void leave() {
    if (!active) return;
    remote.send({'type': 'party_leave', 'room': room});
    _reset();
  }

  void _reset() {
    room = null;
    hostId = hostName = null;
    members = const [];
    _st = null;
    _held = false;
    _bufSent = false;
    _syncGen++;
    _lastWaiting = '';
    if (_rateAdj && !_disposed) {
      _rateAdj = false;
      try {
        player.setRate(1.0);
      } catch (_) {}
    }
    _changed();
  }

  // ======== mensajes del servidor ========

  void _onMsg(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'party_state':
        _onState(m);
      case 'party_end':
        if ('${m['room']}' == room) {
          toast('${m['reason'] ?? 'La sala terminó.'}');
          _reset();
        }
    }
  }

  void _onState(Map<String, dynamic> m) {
    final r = '${m['room']}';
    if (room == null) {
      // Respuesta a "Crear sala": el servidor marca con `by` quién la creó.
      if (!_awaiting || '${m['by']}' != (myId() ?? '')) return;
      room = r;
      _awaiting = false;
      _awaitTimer?.cancel();
      if (!_ours(player.state.rate)) player.setRate(1.0);
    } else if (r != room) {
      return;
    }
    _st = m;
    hostId = m['host'] as String?;
    hostName = m['hostName'] as String?;
    control = '${m['control'] ?? 'all'}';
    members = [
      for (final x in (m['members'] as List? ?? const []))
        if (x is Map) PartyMember.fromJson(x.cast<String, dynamic>())
    ];
    if (m['denied'] == true) {
      toast('Solo ${hostName ?? 'quien creó la sala'} controla la reproducción.');
    }
    _changed();
    // La sala pasó a otro video (capítulo siguiente): se abre aquí también.
    if ('${m['videoId']}' != videoId()) {
      _followVideo();
      return;
    }
    if (!ready() || _held || _switching) return;
    _apply();
    // Aviso cuando alguien más está cargando y por eso la sala espera.
    final waiting = [
      for (final x in members)
        if (x.buffering && x.id != myId()) x.name
    ].join(', ');
    if (waiting.isNotEmpty && waiting != _lastWaiting) {
      toast('Esperando a $waiting…');
    }
    _lastWaiting = waiting;
  }

  Future<void> _followVideo() async {
    if (_switching || _st == null) return;
    final id = '${_st!['videoId']}';
    _switching = true;
    _held = true;
    _reportBuf(true);
    try {
      await switchTo(id);
    } finally {
      _switching = false;
    }
    // Si no se pudo abrir, que la sala no se quede esperando por nosotros.
    if (!_disposed && active && videoId() != id) {
      _held = false;
      _reportBuf(false);
      toast('No se pudo abrir el video de la sala.');
    }
  }

  // ======== sincronizar este reproductor con la sala ========

  int _expectedMs() {
    final s = _st!;
    final pos = (s['posMs'] as num).toInt();
    if (s['playing'] != true) return pos;
    final e = pos + (remote.serverNow() - (s['at'] as num).toInt());
    return e < 0 ? 0 : e;
  }

  /// El reproductor terminó de abrir un video (el de la sala). Se salta a la posición exacta
  /// de la sala y se reproduce o se deja en pausa como ella.
  Future<void> onOpened() async {
    if (!active) {
      final c = _createPending;
      if (c != null) {
        _createPending = null;
        create(control: c);
      }
      return;
    }
    _lastPosAt = 0;
    final gen = ++_syncGen;
    _held = true;
    for (var i = 0; i < 50 && _st == null && gen == _syncGen && active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_disposed || !active || gen != _syncGen) return;
    if (_st == null) {
      _held = false;
      _reportBuf(false);
      return;
    }
    if ('${_st!['videoId']}' != videoId()) {
      _held = false;
      _followVideo();
      return;
    }
    await _hardSeek(gen);
    if (_disposed || !active || gen != _syncGen) return;
    final playing = _st!['playing'] == true;
    _ignoreFor(1500);
    if (playing != player.state.playing) {
      playing ? await player.play() : await player.pause();
    }
    _held = false;
    _lastPosAt = 0;
    _reportBuf(false);
  }

  /// Salta a la posición de la sala y comprueba que llegó (un salto antes de que el reproductor
  /// arranque a veces se pierde), con varios intentos.
  Future<void> _hardSeek(int gen) async {
    for (var i = 0; i < 4; i++) {
      if (_disposed || !active || gen != _syncGen || _st == null) return;
      _ignoreFor(2500);
      await player.seek(Duration(milliseconds: _expectedMs()));
      try {
        await player.stream.position
            .firstWhere((p) => (p.inMilliseconds - _expectedMs()).abs() < 1500)
            .timeout(Duration(milliseconds: 1500 + 500 * i));
        return;
      } catch (_) {}
    }
  }

  void _onTick() {
    if (_now() - _localAt < 1500) return;
    _apply();
  }

  /// Compara este reproductor con la sala y lo corrige.
  void _apply() {
    if (_st == null || !active || !ready() || _held || _switching) return;
    if (_now() < _ignoreUntil) return;
    final playing = _st!['playing'] == true;
    final exp = _expectedMs();
    final drift = player.state.position.inMilliseconds - exp; // >0: vamos adelantados
    if (player.state.playing != playing) {
      _ignoreFor(1200);
      playing ? player.play() : player.pause();
    }
    if (!playing) {
      if (drift.abs() > 400) {
        _ignoreFor(2000);
        player.seek(Duration(milliseconds: exp));
      }
      _setRate(1.0);
      return;
    }
    if (drift.abs() > 2000) {
      _ignoreFor(2500);
      player.seek(Duration(milliseconds: exp));
      _setRate(1.0);
    } else if (drift.abs() > 150) {
      _setRate(drift > 0 ? 0.95 : 1.05); // se alcanza sin saltos
    } else if (drift.abs() < 40) {
      _setRate(1.0);
    }
  }

  bool _ours(double r) =>
      (r - 1.0).abs() < 0.001 || (r - 0.95).abs() < 0.001 || (r - 1.05).abs() < 0.001;

  void _setRate(double r) {
    if ((player.state.rate - r).abs() < 0.001) return;
    if (r != 1.0) _rateAdj = true;
    player.setRate(r);
  }

  // ======== lo que hace la persona en su reproductor ========

  void _onRate(double r) {
    if (!active || _disposed || _ours(r)) return;
    // Con velocidades distintas la sala no se podría mantener sincronizada.
    player.setRate(1.0);
    toast('En una sala la velocidad es la normal.');
  }

  void _onPlaying(bool p) {
    if (!active || _st == null || !ready() || _held || _switching) return;
    if (_now() < _ignoreUntil) return;
    if (p == (_st!['playing'] == true)) return; // ya coincide con la sala
    _sendCtl(p ? 'play' : 'pause');
  }

  void _onPosition(Duration pos) {
    final ms = pos.inMilliseconds, now = _now();
    final last = _lastPos, lastAt = _lastPosAt;
    _lastPos = ms;
    _lastPosAt = now;
    if (!active || _st == null || !ready() || _held || _switching || lastAt == 0) return;
    if (now < _ignoreUntil) return;
    // Un salto: la posición cambió mucho más (o hacia atrás) de lo que explica el tiempo
    // transcurrido. Una parada por carga no cuenta: ahí la posición casi no cambia.
    final jump = ms - last, elapsed = now - lastAt;
    final fwd = (elapsed * player.state.rate).round() + 1500;
    if (jump >= -1500 && jump <= fwd) return;
    // mpv a veces vuelve a 0 por su cuenta: eso no se contagia a toda la sala.
    if (ms < 5000 && last > 60000) return;
    _sendCtl('seek');
  }

  void _onBuffering(bool b) {
    _bufTimer?.cancel();
    if (!active || _disposed) return;
    if (b) {
      // Se avisa solo si la carga dura: los saltos cortos de mpv no cuentan.
      _bufTimer = Timer(const Duration(milliseconds: 700), () => _reportBuf(true));
    } else if (!_held) {
      _reportBuf(false);
    }
  }

  void _reportBuf(bool b) {
    if (!active || _bufSent == b) return;
    _bufSent = b;
    remote.send({'type': 'party_buf', 'room': room, 'buffering': b});
  }

  void _sendCtl(String action) {
    _localAt = _now();
    remote.send({
      'type': 'party_ctl',
      'room': room,
      'action': action,
      'posMs': player.state.position.inMilliseconds,
    });
  }

  @override
  void dispose() {
    _disposed = true;
    if (active) remote.send({'type': 'party_leave', 'room': room});
    _msgSub.cancel();
    _playSub.cancel();
    _posSub.cancel();
    _bufSub.cancel();
    _rateSub.cancel();
    _tick.cancel();
    _bufTimer?.cancel();
    _awaitTimer?.cancel();
    super.dispose();
  }
}

// =================== hoja "Ver juntos" ===================

Future<void> showPartySheet(BuildContext context, PartyController c) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _PartySheet(c: c),
  );
}

class _PartySheet extends ConsumerStatefulWidget {
  const _PartySheet({required this.c});
  final PartyController c;
  @override
  ConsumerState<_PartySheet> createState() => _PartySheetState();
}

class _PartySheetState extends ConsumerState<_PartySheet> {
  String _control = 'all';
  final _invited = <String>{};

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final devices = ref.watch(remoteProvider).others;
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: c,
      builder: (_, __) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.groups_rounded),
                const SizedBox(width: 10),
                Text('Ver juntos', style: theme.textTheme.titleLarge),
              ]),
              const SizedBox(height: 10),
              if (!c.active) ..._create(c, theme) else ..._room(c, theme, devices),
            ]),
      ),
    );
  }

  List<Widget> _create(PartyController c, ThemeData theme) => [
        const Text(
            'Crea una sala e invita a otros dispositivos: verán esto sincronizado y las '
            'pausas y los saltos se aplican a todos a la vez.'),
        const SizedBox(height: 16),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'all', label: Text('Todos controlan')),
            ButtonSegment(value: 'host', label: Text('Solo yo')),
          ],
          selected: {_control},
          onSelectionChanged: (s) => setState(() => _control = s.first),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
              onPressed: c.canCreate ? () => c.create(control: _control) : null,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Crear sala')),
        ),
      ];

  List<Widget> _room(
      PartyController c, ThemeData theme, List<RemoteDevice> devices) {
    final inRoom = {for (final m in c.members) m.id};
    final others = [for (final d in devices) if (!inRoom.contains(d.id)) d];
    return [
      Text('En la sala (${c.members.length})', style: theme.textTheme.titleSmall),
      CinemaHall(
        api: ref.watch(apiProvider),
        members: c.members,
        myId: ref.read(remoteProvider).myId,
        hostId: c.hostId,
        compact: true,
      ),
      const Divider(height: 24),
      if (c.isHost)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Todos pueden pausar y mover'),
          subtitle: const Text('Si lo apagas, solo tú controlas la reproducción.'),
          value: c.control == 'all',
          onChanged: (v) => c.setControl(v ? 'all' : 'host'),
        )
      else
        Text(c.control == 'all'
            ? 'Todos pueden pausar y mover.'
            : 'Solo ${c.hostName ?? 'quien creó la sala'} controla la reproducción.'),
      const Divider(height: 24),
      Text('Invitar', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      if (others.isEmpty)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No hay más dispositivos conectados al servidor.'))
      else
        for (final d in others)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.devices_rounded),
            title: Text(d.profile?.username ?? d.name),
            subtitle: d.profile == null ? null : Text(d.name),
            trailing: _invited.contains(d.id)
                ? const Text('Invitado')
                : TextButton(
                    onPressed: () {
                      c.invite(d.id);
                      setState(() => _invited.add(d.id));
                    },
                    child: const Text('Invitar')),
          ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
            onPressed: () {
              c.leave();
              Navigator.of(context).maybePop();
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Salir de la sala')),
      ),
    ];
  }
}
