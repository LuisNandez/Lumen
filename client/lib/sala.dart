import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import 'cinema.dart';
import 'core.dart';
import 'main.dart' show joinParty, startParty;
import 'remote.dart';
import 'theater.dart' show detailProvider;
import 'tv.dart' show TvTextEntry, tvModeProvider;
import 'voice.dart';

const _bg = Color(0xFF0B0B10);
const _red = Color(0xFFE50914);
const _speakGreen = Color(0xFF4CFF8A);

/// Pestaña "Sala": la sala de cine de "ver juntos". Muestra la función que está en curso
/// (portada horizontal en la pantalla) y a quienes están sentados viéndola, cada uno con la
/// foto de su perfil; desde aquí se puede entrar en una función o abrir una sala nueva.
class SalaScreen extends ConsumerStatefulWidget {
  const SalaScreen({super.key});

  @override
  ConsumerState<SalaScreen> createState() => _SalaScreenState();
}

class _SalaScreenState extends ConsumerState<SalaScreen> {
  String? _sel; // sala elegida cuando hay varias
  String?
      _opening; // sala cuyo reproductor ya se abrió (para no abrirlo dos veces)
  bool _tv = false; // modo TV: el botón principal toma el foco del mando

  RemoteNotifier get _remote => ref.read(remoteProvider.notifier);

  /// La sala en la que estoy sentado, si estoy en alguna.
  PartyInfo? _mineOf(List<PartyInfo> list, String? myId) {
    if (myId == null) return null;
    for (final p in list) {
      if (p.members.any((m) => m.id == myId)) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    final offline = ref.watch(serverOfflineProvider);
    final remote = ref.watch(remoteProvider);
    final parties = remote.parties;
    final myId = remote.myId;

    // Cuando quien creó la sala pulsa "Comenzar", todos los sentados pasan al reproductor.
    ref.listen<List<PartyInfo>>(remoteProvider.select((r) => r.parties),
        (prev, next) {
      final id = ref.read(remoteProvider).myId;
      final before = _mineOf(prev ?? const [], id), now = _mineOf(next, id);
      if (now == null) {
        _opening = null;
        return;
      }
      if (before != null &&
          before.id == now.id &&
          !before.started &&
          now.started &&
          _opening != now.id) {
        _opening = now.id;
        joinParty(context, ref, room: now.id, videoId: now.videoId);
      }
    });

    final mine = _mineOf(parties, myId);
    PartyInfo? sel = mine;
    if (sel == null) {
      for (final p in parties) {
        if (p.id == _sel) sel = p;
      }
      sel ??= parties.isEmpty ? null : parties.first;
    }
    final lobby = sel != null && !sel.started;
    final iAmIn = mine != null && mine.id == sel?.id;

    if (offline) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(
            child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('La sala necesita el servidor encendido.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 15)))),
      );
    }

    // Portada horizontal de lo que se va a ver (o su miniatura si no tiene).
    String? backdrop;
    if (sel != null && api != null) {
      final it = ref.watch(detailProvider(sel.videoId)).valueOrNull?.item;
      if (it != null) {
        backdrop = it.backdropV > 0 ? api.backdropUrl(it) : api.thumbUrl(it.id);
      }
    }

    final subtitle = sel == null
        ? 'Ver juntos, en sincronía.'
        : iAmIn && lobby
            ? 'Estás sentado en la sala'
            : lobby
                ? 'Una sala espera a que empiece la función'
                : parties.length > 1
                    ? '${parties.length} funciones en curso'
                    : 'Función en curso';

    final tv = ref.watch(tvModeProvider);
    _tv = tv;
    // Pantalla ancha (TV, tablet, escritorio): butacas a la izquierda y la información a la
    // derecha, así con el mando no hay que bajar para llegar a los botones.
    final wide = tv || MediaQuery.sizeOf(context).width >= 900;

    // Varias salas abiertas y yo no estoy sentado en ninguna: hay que poder elegir.
    final choose = parties.length > 1 && mine == null;

    // Móvil: el selector de salas va en fichas bajo el título. En pantalla ancha va en el panel
    // de la derecha (ahí es donde está el mando/ratón y hay que poder llegar con las flechas).
    final heading = <Widget>[
      Padding(
        padding: EdgeInsets.fromLTRB(wide ? 28 : 20, 14, 20, 4),
        child: Text('Sala',
            style: TextStyle(
                fontSize: wide ? 32 : 30,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5)),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(wide ? 28 : 20, 0, 20, wide ? 6 : 10),
        child: Text(subtitle, style: const TextStyle(color: Colors.white54)),
      ),
      if (choose && !wide)
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            children: [
              for (final p in parties)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${p.title} · ${p.members.length}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    selected: p.id == sel?.id,
                    onSelected: (_) => setState(() => _sel = p.id),
                  ),
                ),
            ],
          ),
        ),
    ];

    // Solo esta parte se redibuja cuando cambia quién habla (varias veces por segundo).
    // [fitHeight] != null: la sala se ajusta a esa altura y se ve entera, sin bajar.
    Widget hallFor(double? fitHeight) => Consumer(builder: (context, ref, _) {
          final speaking = (iAmIn && lobby)
              ? ref.watch(voiceProvider.select((v) => v.speaking))
              : const <String>{};
          return CinemaHall(
            api: api,
            members: sel?.members ?? const [],
            myId: myId,
            hostId: sel?.hostId,
            backdropUrl: backdrop,
            title: sel?.title,
            playing: sel?.playing ?? false,
            waiting: lobby,
            empty: sel == null,
            speaking: speaking,
            fitHeight: fitHeight,
          );
        });

    final info = sel == null
        ? _emptyInfo()
        : (iAmIn && lobby)
            ? _lobbyInfo(sel, myId)
            : _roomInfo(sel, iAmIn);

    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        bottom: false,
        child: wide
            // Pantalla ancha (TV, tablet, escritorio): la sala entera a la izquierda, ajustada
            // a la altura de la pantalla (no se desplaza), y a la derecha un panel con todo lo
            // que se puede pulsar. Con el mando todo queda en una sola columna de foco.
            ? LayoutBuilder(builder: (context, c) {
                final panelW = (c.maxWidth * (tv ? 0.34 : 0.32))
                    .clamp(380.0, 520.0)
                    .toDouble();
                return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ...heading,
                              Expanded(
                                child: LayoutBuilder(
                                    builder: (context, hc) =>
                                        hallFor(hc.maxHeight)),
                              ),
                            ]),
                      ),
                      SizedBox(
                        width: panelW,
                        child: FocusTraversalGroup(
                          child: ListView(
                              padding:
                                  EdgeInsets.fromLTRB(12, tv ? 24 : 26, 28, 28),
                              children: [
                                if (choose) _roomPicker(parties, sel),
                                info,
                              ]),
                        ),
                      ),
                    ]);
              })
            : ListView(padding: const EdgeInsets.only(bottom: 28), children: [
                ...heading,
                hallFor(null),
                Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: info),
              ]),
      ),
    );
  }

  // --- Estilos pensados para verse desde el sofá y pulsarse con el mando ---------------------

  /// Botón principal rojo (texto blanco: el del tema salía oscuro sobre el rojo).
  ButtonStyle get _primaryStyle => FilledButton.styleFrom(
        backgroundColor: _red,
        foregroundColor: Colors.white,
        padding: EdgeInsets.symmetric(vertical: _tv ? 20 : 14),
        textStyle:
            TextStyle(fontSize: _tv ? 17 : null, fontWeight: FontWeight.w700),
      );

  ButtonStyle get _secondaryStyle => OutlinedButton.styleFrom(
        padding: EdgeInsets.symmetric(vertical: _tv ? 18 : 12),
        textStyle:
            TextStyle(fontSize: _tv ? 16 : null, fontWeight: FontWeight.w600),
      );

  TextStyle get _titleStyle =>
      TextStyle(fontSize: _tv ? 24 : 18, fontWeight: FontWeight.w800);

  /// Salas abiertas (pantalla ancha): una fila de fichas. Con el mando, ◀ ▶ pasan de una sala a
  /// otra (la de la izquierda cambia al enfocar la ficha) y ▼ baja directo a los botones.
  Widget _roomPicker(List<PartyInfo> parties, PartyInfo? sel) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 0, 0, 6),
          child: Text('Salas abiertas',
              style: TextStyle(
                  color: Colors.white54,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3)),
        ),
        SizedBox(
          height: _tv ? 64 : 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
            children: [
              for (final p in parties)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onFocusChange: (f) {
                      if (f && _tv && _sel != p.id) setState(() => _sel = p.id);
                    },
                    child: ChoiceChip(
                      label: Text('${p.title} · ${p.members.length}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      selected: p.id == sel?.id,
                      onSelected: (_) => setState(() => _sel = p.id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _emptyInfo() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('No hay ninguna función ahora mismo.',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        const Text(
            'Abre una sala, elige qué ver e invita a otros dispositivos: se sentarán en la '
            'sala y, cuando estéis todos, la función empieza a la vez para todos.',
            style: TextStyle(color: Colors.white60, height: 1.35)),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
              style: _primaryStyle,
              onPressed: _newRoom,
              autofocus: _tv,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Abrir una sala')),
        ),
      ]);

  /// Estoy sentado en una sala que aún no empezó.
  Widget _lobbyInfo(PartyInfo p, String? myId) {
    final isHost = p.hostId == myId;
    final n = p.members.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(p.title,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: _titleStyle),
      const SizedBox(height: 4),
      Text(
          '$n ${n == 1 ? 'persona sentada' : 'personas sentadas'} · '
          '${isHost ? 'empieza cuando tú quieras' : 'esperando a que ${p.hostName.isEmpty ? 'quien la creó' : p.hostName} comience'}',
          style: const TextStyle(color: Colors.white60)),
      const SizedBox(height: 14),
      if (isHost)
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
              style: _primaryStyle,
              onPressed: () =>
                  _remote.send({'type': 'party_start', 'room': p.id}),
              autofocus: _tv,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Comenzar función')),
        )
      else
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: Colors.white10, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Icon(Icons.hourglass_top_rounded,
                size: 20, color: Colors.amber),
            const SizedBox(width: 10),
            Expanded(
                child: Text(
                    'Esperando a que ${p.hostName.isEmpty ? 'quien creó la sala' : p.hostName} '
                    'comience la función…',
                    style: const TextStyle(color: Colors.white70))),
          ]),
        ),
      const SizedBox(height: 12),
      _VoicePanel(party: p, myId: myId),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
            style: _secondaryStyle,
            onPressed: () => _invite(p),
            autofocus: _tv && !isHost,
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Invitar a alguien')),
      ),
      if (isHost)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Todos pueden pausar y mover'),
          subtitle: const Text('Si lo apagas, solo tú controlas la función.',
              style: TextStyle(color: Colors.white54)),
          value: p.control == 'all',
          onChanged: (v) => _remote.send({
            'type': 'party_set',
            'room': p.id,
            'control': v ? 'all' : 'host'
          }),
        )
      else
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
              p.control == 'all'
                  ? 'Todos podrán pausar y mover.'
                  : 'Solo ${p.hostName.isEmpty ? 'quien la creó' : p.hostName} controlará la función.',
              style: const TextStyle(color: Colors.white54)),
        ),
      const SizedBox(height: 4),
      Center(
        child: TextButton.icon(
            onPressed: () =>
                _remote.send({'type': 'party_leave', 'room': p.id}),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Salir de la sala')),
      ),
    ]);
  }

  /// Una sala en la que no estoy (en el vestíbulo o ya en marcha).
  Widget _roomInfo(PartyInfo p, bool iAmIn) {
    final n = p.members.length;
    final control = p.control == 'all'
        ? 'Todos controlan'
        : 'Solo ${p.hostName.isEmpty ? 'quien la creó' : p.hostName} controla';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(p.title,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: _titleStyle),
      const SizedBox(height: 4),
      Text(
          '${p.hostName.isEmpty ? 'Alguien' : p.hostName} abrió la sala · '
          '$n ${n == 1 ? 'persona' : 'personas'}'
          '${p.started ? '' : ' · esperando para empezar'}',
          style: const TextStyle(color: Colors.white60)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, children: [
        Chip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(
                p.control == 'all' ? Icons.groups_rounded : Icons.lock_outline,
                size: 16),
            label: Text(control)),
      ]),
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
            style: _primaryStyle,
            onPressed: () => _join(p),
            autofocus: _tv,
            icon: const Icon(Icons.event_seat_rounded),
            label: Text(
                p.started ? 'Unirme a la función' : 'Sentarme en la sala')),
      ),
      if (!iAmIn) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
              style: _secondaryStyle,
              onPressed: _newRoom,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Abrir otra sala')),
        ),
      ],
    ]);
  }

  /// En pantallas anchas (TV, escritorio) las hojas no ocupan todo el ancho: quedan centradas.
  BoxConstraints? _sheetConstraints() => MediaQuery.sizeOf(context).width >= 900
      ? const BoxConstraints(maxWidth: 680)
      : null;

  void _join(PartyInfo p) {
    if (p.started) {
      joinParty(context, ref, room: p.id, videoId: p.videoId);
    } else {
      _remote
          .send({'type': 'party_join', 'room': p.id}); // te sientas y esperas
    }
  }

  void _invite(PartyInfo p) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: _sheetConstraints(),
      builder: (_) => _InviteSheet(room: p.id),
    );
  }

  void _newRoom() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: _sheetConstraints(),
      builder: (_) => _NewRoomSheet(onPick: (item, control) {
        startParty(context, ref, item, control);
      }),
    );
  }
}

/// Chat de voz del vestíbulo: se activa y desactiva con el interruptor; ya activado se puede
/// silenciar el micrófono y elegir altavoz. Las butacas muestran quién habla.
class _VoicePanel extends ConsumerWidget {
  const _VoicePanel({required this.party, required this.myId});
  final PartyInfo party;
  final String? myId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(voiceProvider);
    final voice = ref.read(voiceProvider.notifier);
    final inVoice = party.members.where((m) => m.voice).length;
    final names = [
      for (final m in party.members)
        if (v.speaking.contains(m.id)) (m.id == myId ? 'Tú' : m.label)
    ];
    final on = v.active || v.connecting;
    final subtitle = v.connecting
        ? 'Conectando…'
        : v.active
            ? (v.listenOnly
                ? 'Solo escuchas (sin micrófono) · $inVoice en el chat'
                : '$inVoice ${inVoice == 1 ? 'persona' : 'personas'} en el chat de voz')
            : 'Habla con quienes esperan la función';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: v.active ? const Color(0x664CFF8A) : Colors.transparent),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(v.active ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
              color: v.active ? _speakGreen : Colors.white70),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Chat de voz',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              Text(subtitle,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12.5)),
            ]),
          ),
          Switch(
            value: on,
            onChanged:
                v.connecting ? null : (x) => x ? voice.start() : voice.stop(),
          ),
        ]),
        if (v.active) ...[
          const SizedBox(height: 4),
          Row(children: [
            if (!v.listenOnly)
              Expanded(
                child: FilledButton.tonalIcon(
                  style: v.muted
                      ? FilledButton.styleFrom(
                          backgroundColor: const Color(0x55D32F2F),
                          foregroundColor: Colors.white)
                      : null,
                  onPressed: voice.toggleMute,
                  icon: Icon(
                      v.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      size: 20),
                  label: Text(
                      v.muted ? 'Micrófono en silencio' : 'Micrófono activo'),
                ),
              ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: v.speaker ? 'Altavoz' : 'Auricular',
              onPressed: voice.toggleSpeaker,
              icon: Icon(
                  v.speaker ? Icons.volume_up_rounded : Icons.hearing_rounded),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 0, 2),
            child: Row(children: [
              Icon(Icons.record_voice_over_rounded,
                  size: 16,
                  color: names.isEmpty ? Colors.white30 : _speakGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    names.isEmpty
                        ? 'Nadie habla ahora'
                        : 'Hablando: ${names.join(', ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            names.isEmpty ? FontWeight.w400 : FontWeight.w600,
                        color: names.isEmpty ? Colors.white38 : _speakGreen)),
              ),
            ]),
          ),
        ],
        if (v.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 8, 2),
            child: Text(v.error!,
                style:
                    const TextStyle(color: Colors.redAccent, fontSize: 12.5)),
          ),
      ]),
    );
  }
}

/// Invitar a otros dispositivos conectados a sentarse en la sala.
class _InviteSheet extends ConsumerStatefulWidget {
  const _InviteSheet({required this.room});
  final String room;
  @override
  ConsumerState<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<_InviteSheet> {
  final _invited = <String>{};

  @override
  Widget build(BuildContext context) {
    final r = ref.watch(remoteProvider);
    PartyInfo? room;
    for (final p in r.parties) {
      if (p.id == widget.room) room = p;
    }
    final inRoom = {
      for (final m in room?.members ?? const <PartyMember>[]) m.id
    };
    final others = [
      for (final d in r.others)
        if (!inRoom.contains(d.id)) d
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.person_add_alt_1_rounded),
              const SizedBox(width: 10),
              Text('Invitar', style: Theme.of(context).textTheme.titleLarge),
            ]),
            const SizedBox(height: 8),
            if (others.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No hay más dispositivos conectados al servidor.',
                      style: TextStyle(color: Colors.white60)))
            else
              for (final d in others)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices_rounded),
                  title: Text(d.profile?.username ?? d.name),
                  subtitle: d.profile == null ? null : Text(d.name),
                  trailing: _invited.contains(d.id)
                      ? const Text('Invitado')
                      : TextButton(
                          onPressed: () {
                            ref.read(remoteProvider.notifier).send({
                              'type': 'party_invite',
                              'room': widget.room,
                              'to': d.id
                            });
                            setState(() => _invited.add(d.id));
                          },
                          child: const Text('Invitar')),
                ),
          ]),
    );
  }
}

/// Elegir qué ver en la sala nueva (películas y series de la biblioteca).
class _NewRoomSheet extends ConsumerStatefulWidget {
  const _NewRoomSheet({required this.onPick});
  final void Function(VideoItem item, String control) onPick;
  @override
  ConsumerState<_NewRoomSheet> createState() => _NewRoomSheetState();
}

class _NewRoomSheetState extends ConsumerState<_NewRoomSheet> {
  String _q = '';
  String _control = 'all';

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    final lib = ref.watch(libraryProvider).valueOrNull ?? const <VideoItem>[];
    final shows = ref.watch(showsProvider).valueOrNull ?? const <ShowItem>[];
    final items = <VideoItem>[
      for (final v in lib)
        if (v.showId == null && !v.isShow) v,
      for (final s in shows) s.toCard(),
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final q = _q.trim().toLowerCase();
    final shown = q.isEmpty
        ? items
        : [
            for (final v in items)
              if (v.title.toLowerCase().contains(q)) v
          ];

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Row(children: [
            const Icon(Icons.theaters_rounded),
            const SizedBox(width: 10),
            Text('¿Qué vais a ver?',
                style: Theme.of(context).textTheme.titleLarge),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('Todos controlan')),
              ButtonSegment(value: 'host', label: Text('Solo yo')),
            ],
            selected: {_control},
            onSelectionChanged: (s) => setState(() => _control = s.first),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: TvTextEntry(
              child: TextField(
            decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar película o serie',
                border: OutlineInputBorder()),
            onChanged: (v) => setState(() => _q = v),
          )),
        ),
        Flexible(
          child: shown.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(28),
                  child: Text('No hay nada que coincida.',
                      style: TextStyle(color: Colors.white54)))
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: shown.length,
                  itemBuilder: (_, i) {
                    final v = shown[i];
                    return ListTile(
                      leading: SizedBox(
                        width: 38,
                        height: 56,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: (api != null && v.posterV > 0)
                              ? Image.network(api.posterUrl(v),
                                  headers: api.authHeaders,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => _noPoster(v))
                              : _noPoster(v),
                        ),
                      ),
                      title: Text(v.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(v.isShow
                          ? 'Serie'
                          : (v.year?.toString() ?? 'Película')),
                      onTap: () {
                        Navigator.pop(context);
                        widget.onPick(v, _control);
                      },
                    );
                  }),
        ),
      ]),
    );
  }

  Widget _noPoster(VideoItem v) => ColoredBox(
      color: Colors.white10,
      child: Icon(v.isShow ? Icons.tv : Icons.movie_outlined,
          color: Colors.white38));
}
