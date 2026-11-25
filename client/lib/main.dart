import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared/shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'audiobooks.dart' show BookNotificationGate;
import 'book_playback.dart';
import 'core.dart';
import 'downloads.dart';
import 'minimal_video_loader.dart';
import 'native.dart';
import 'notifications.dart';
import 'news.dart';
import 'party.dart';
import 'peticiones.dart';
import 'player_controls.dart';
import 'player_params.dart';
import 'progress_sync.dart';
import 'profiles.dart';
import 'remote.dart';
import 'shell.dart';
import 'sounds.dart';
import 'splash.dart';
import 'subtitle_style.dart';
import 'theater.dart';
import 'track_menu.dart';
import 'tv.dart';
import 'tv_intro.dart';
import 'updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  await ensureDeviceName(prefs);
  final downloadsRoot = await prepareDownloadsRoot();
  final isTv =
      await detectTv(); // Android TV / TV box: mismo cliente, interfaz adaptada
  // En TV el aro de foco se pinta siempre. Con la estrategia automática, un solo evento táctil
  // o de puntero (mandos con touchpad / ratón aéreo, "toques" fantasma) pasaba Flutter a modo
  // táctil y los aros desaparecían aunque el foco siguiera moviéndose.
  if (isTv) {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  }
  await Sfx.init(
      enabled: prefs.getBool(Sfx.kPrefKey) ?? true,
      tv: isTv); // sonidos solo en TV
  final theme = ThemeData(
    colorSchemeSeed: Colors.indigo,
    brightness: Brightness.dark,
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Color(0xFFE50914),
    ),
  );
  runApp(ProviderScope(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      downloadsRootProvider.overrideWithValue(downloadsRoot),
      tvModeProvider.overrideWithValue(isTv),
    ],
    child: MaterialApp(
      title: 'Lumen',
      theme: isTv ? tvTheme(theme) : theme,
      navigatorObservers: [SfxNavigatorObserver()],
      builder: isTv
          ? (context, child) => tvTextScale(child ?? const SizedBox())
          : null,
      // TV: video de intro (assets/video) que acaba en negro y se funde con la interfaz.
      // Móvil / escritorio: animación LUMEN de siempre (la app carga debajo y el sonido de
      // bienvenida suena al terminar).
      home: isTv
          ? const TvIntroGate(child: Home())
          : const SplashGate(child: Home()),
    ),
  ));
}

/// Con sesión guardada entra directo a la biblioteca; si no, pide emparejar.
bool _updateDialogOpen = false;

/// Novedades ya anunciadas con un aviso emergente, por perfil: así solo se avisa de lo que
/// llega mientras la app está abierta (no al abrirla ni al cambiar de perfil).
({String? profile, Set<String> known})? _newsAnnounced;

class Home extends ConsumerWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(sessionProvider, (old, next) {
      if (old != null && (old.host != next?.host || old.token != next?.token)) {
        unawaited(BookPlayback.stop());
      }
    });
    if (ref.watch(sessionProvider) == null) return const ConnectScreen();
    ref.read(remoteProvider); // mantiene viva la conexión WebSocket
    ref.read(progressSyncProvider); // sube el progreso pendiente (reintentos)
    ref.read(
        downloadsProvider); // gestor de descargas siempre activo (cola, sincronización)
    ref.read(
        appNotificationsProvider); // avisos: progreso de descargas y peticiones
    // Mantiene cargada la lista de peticiones: así se guarda en el dispositivo aunque
    // nunca se abra la pantalla de Peticiones, y queda disponible con el servidor apagado.
    ref.listen(requestsProvider, (_, __) {});
    // Si la biblioteca cambia (p. ej. se atendió una petición), se recargan las etiquetas.
    ref.listen(libraryProvider, (_, next) {
      if (next is AsyncData) ref.invalidate(requestsProvider);
    });
    // Sonidos de salas: entrar / salir de una sala de "ver juntos" (sin contar caídas de red).
    ref.listen(remoteProvider, (prev, next) {
      if (prev == null || !prev.connected || !next.connected) return;
      final before = _myRoomId(prev), now = _myRoomId(next);
      if (before == null && now != null) {
        Sfx.play(Snd.entrarASala, force: true);
      } else if (before != null && now == null) {
        Sfx.play(Snd.salirDeSala, force: true);
      }
    });
    // Servidor que deja de responder: aviso.
    ref.listen(serverOfflineProvider, (prev, next) {
      if (prev == false && next == true) Sfx.play(Snd.alerta, force: true);
    });
    // Versión nueva en el servidor: se ofrece una vez por versión, sin interrumpir un
    // video (solo si esta pantalla es la que se está viendo). Siempre queda en Ajustes.
    ref.listen(updaterProvider, (_, next) {
      final n = ref.read(updaterProvider.notifier);
      if (next.stage != UpdateStage.available ||
          _updateDialogOpen ||
          (next.info?.versionCode ?? 0) <= n.dismissedCode) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      _updateDialogOpen = true;
      Sfx.play(Snd.notificacion, force: true);
      showUpdateDialog(context).whenComplete(() => _updateDialogOpen = false);
    });
    // Capítulo nuevo de una serie mientras se usa la app: aviso breve con acceso a Novedades.
    ref.listen(newsProvider, (_, next) {
      final data = next.valueOrNull;
      if (next.isLoading || data == null) return;
      final profile =
          ref.read(profilesProvider).valueOrNull?.currentProfile?.key;
      final unread = [
        for (final i in data.items)
          if (i.unread) i
      ];
      final keys = {for (final i in unread) '${i.showId}:${i.latestMs}'};
      final prev = _newsAnnounced;
      _newsAnnounced = (profile: profile, known: keys);
      if (prev == null || prev.profile != profile)
        return; // primera carga o cambio de perfil
      final fresh = [
        for (final i in unread)
          if (!prev.known.contains('${i.showId}:${i.latestMs}')) i
      ];
      if (fresh.isEmpty || ModalRoute.of(context)?.isCurrent != true) return;
      Sfx.play(Snd.notificacion, force: true);
      final text = fresh.length == 1
          ? 'Nuevo capítulo de ${fresh.first.show}'
              ' · ${(fresh.first.firstPending ?? fresh.first.episodes.first).label}'
          : 'Capítulos nuevos en ${fresh.length} series';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(text),
            action: SnackBarAction(
                label: 'VER',
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const NewsScreen())))));
    });
    ref.listen(commandsProvider, (_, next) {
      final m = next.valueOrNull;
      if (m != null && m['action'] == 'open')
        _openRemote(context, ref, m['videoId'] as String);
    });
    // Alguien te invita a ver algo juntos.
    ref.listen(partyInviteProvider, (_, next) {
      final m = next.valueOrNull;
      if (m != null) {
        Sfx.play(Snd.notificacion, force: true);
        _askJoinParty(context, ref, m);
      }
    });
    // Servidor apagado: solo el teatro con las películas descargadas.
    if (ref.watch(serverOfflineProvider)) {
      return const BookNotificationGate(
          child: HomeShell(home: OfflineTheaterScreen()));
    }
    // ¿Quién está viendo? Sin perfil activo se pide elegir uno; si el perfil tiene PIN, se
    // pide al abrir la app. Con un servidor sin perfiles (o sin respuesta) no se pide nada.
    final profiles = ref.watch(profilesProvider);
    final pdata = profiles.valueOrNull;
    if (pdata == null) {
      if (profiles.isLoading) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
    } else {
      final cur = pdata.currentProfile;
      if (cur == null) return const ProfilePickerScreen(dismissible: false);
      if (cur.hasPin && ref.watch(unlockedProfileProvider) != cur.key) {
        return ProfileLockScreen(profile: cur);
      }
    }
    // La biblioteca siempre se muestra en modo teatro (la vista de lista se eliminó).
    return const BookNotificationGate(child: HomeShell(home: TheaterScreen()));
  }
}

/// Id de la sala en la que estoy sentado (null si en ninguna).
String? _myRoomId(RemoteState r) {
  final me = r.myId;
  if (me == null) return null;
  for (final p in r.parties) {
    if (p.members.any((m) => m.id == me)) return p.id;
  }
  return null;
}

/// Invitación a ver algo juntos: si se acepta, se abre el reproductor dentro de la sala.
Future<void> _askJoinParty(
    BuildContext context, WidgetRef ref, Map<String, dynamic> m) async {
  final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: const Text('Ver juntos'),
            content: Text(
                '${m['fromName'] ?? 'Alguien'} te invita a ver «${m['title'] ?? ''}» '
                'en sincronía.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Ahora no')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Unirse')),
            ],
          ));
  if (ok != true || !context.mounted) return;
  final room = '${m['room']}';
  PartyInfo? party;
  for (final p in ref.read(remoteProvider).parties) {
    if (p.id == room) party = p;
  }
  if (party != null && !party.started) {
    // La función aún no empieza: te sientas en la sala y esperas en la pestaña Sala.
    ref
        .read(remoteProvider.notifier)
        .send({'type': 'party_join', 'room': room});
    Navigator.of(context).popUntil(
        (r) => r.isFirst); // si estabas viendo algo, vuelves a la barra
    ref.read(tabRequestProvider.notifier).request(1);
    return;
  }
  await joinParty(context, ref, room: room, videoId: '${m['videoId']}');
}

/// Entra en una sala que ya existe: abre su video en el reproductor y se sincroniza.
Future<void> joinParty(BuildContext context, WidgetRef ref,
    {required String room, required String videoId}) async {
  final api = ref.read(apiProvider);
  if (api == null) return;
  try {
    final d = await api.detail(videoId);
    if (!context.mounted) return;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute(
        builder: (_) => PlayerScreen(
            api: api,
            item: d.item,
            resume: const ResumeInfo.start(),
            party: PartyJoin(room))));
  } catch (_) {}
}

/// Abre una sala nueva con [v] (de una serie, su siguiente capítulo). [control]: 'all' o 'host'.
/// No empieza a reproducir: la sala queda en el vestíbulo (pestaña Sala) esperando a que se
/// sienten los demás, y quien la creó pulsa "Comenzar".
Future<void> startParty(
    BuildContext context, WidgetRef ref, VideoItem v, String control) async {
  final api = ref.read(apiProvider);
  if (api == null) return;
  try {
    var item = v;
    if (v.isShow) {
      final d = await api.show(v.id);
      if (d.episodes.isEmpty) return;
      item = d.episodes.firstWhere((e) => e.id == d.show.nextId,
          orElse: () => d.episodes.first);
    }
    // Arranca donde la persona se quedó, salvo que ya estuviera terminado.
    final dur = item.durationMs ?? 0;
    final pos =
        (dur > 0 && item.positionMs > 30000 && item.positionMs < dur * 0.95)
            ? item.positionMs
            : 0;
    ref.read(remoteProvider.notifier).send({
      'type': 'party_create',
      'videoId': item.id,
      'title': item.isEpisode
          ? '${item.show ?? item.title} · ${item.episodeLabel}'
          : item.title,
      'posMs': pos,
      'playing': false,
      'control': control,
      'lobby': true,
    });
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(errorSnack(errText(e)));
    }
  }
}

/// Otro dispositivo pidió reproducir un video aquí.
Future<void> _openRemote(BuildContext context, WidgetRef ref, String id) async {
  final api = ref.read(apiProvider);
  if (api == null) return;
  try {
    final d = await api.detail(id);
    if (!context.mounted) return;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    nav.push(MaterialPageRoute(
        builder: (_) => PlayerScreen(
            api: api, item: d.item, resume: ResumeInfo.fresh(d.item))));
  } catch (_) {}
}

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});
  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

/// Puerto por defecto del servidor, para cuando se escribe solo la IP.
const _kDefaultPort = 8080;

/// "192.168.1.20" -> "192.168.1.20:8080". Si ya trae puerto (o es una dirección web) no se toca.
String _withPort(String h) {
  final t = h.trim();
  if (t.isEmpty || t.startsWith('http') || t.contains(':')) return t;
  return '$t:$_kDefaultPort';
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  late final _host = TextEditingController(
      text: ref.read(prefsProvider).getString('host') ?? '');
  final _pin = TextEditingController();
  Timer? _retry;
  bool _busy = false;
  bool _touched =
      false; // la persona empezó a escribir: se deja de conectar sola
  bool _searching = true;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _auto();
    // Mientras no haya conexión se sigue buscando (el servidor puede arrancar después).
    _retry = Timer.periodic(const Duration(seconds: 4), (_) => _auto());
  }

  @override
  void dispose() {
    _retry?.cancel();
    _host.dispose();
    _pin.dispose();
    super.dispose();
  }

  /// Busca el servidor en la red y, si deja entrar sin PIN, se empareja solo.
  /// Sin IP, sin puerto y sin PIN.
  Future<void> _auto() async {
    if (_busy || _touched || !mounted) return;
    _busy = true;
    try {
      final list = await discoverServers();
      if (!mounted || _touched) return;
      final saved = ref.read(prefsProvider).getString('host');
      DiscoveredServer? s;
      for (final x in list) {
        if (x.address == saved) s = x; // el último servidor usado, si sigue ahí
      }
      s ??= list.isEmpty ? null : list.first;
      if (s == null) {
        if (!_searching) setState(() => _searching = true);
        return;
      }
      if (!s.info.open) {
        // Este servidor tiene la conexión automática apagada: toca escribir el PIN.
        setState(() {
          _host.text = s!.address;
          _searching = false;
          _notice = 'Este servidor pide PIN. Escríbelo abajo.';
        });
        return;
      }
      // PIN fijo que la app ya conoce: la persona no escribe nada.
      final token = await Api.pair(
          s.address, kAutoPin, deviceName(ref.read(prefsProvider)));
      await ref
          .read(sessionProvider.notifier)
          .save(Session(s.address, s.info.name, token));
    } catch (_) {
      // Sin red o el servidor no respondió: se reintenta solo.
    } finally {
      _busy = false;
    }
  }

  Future<void> _pair() async {
    _touched = true;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final host = _withPort(_host.text);
      final info = await Api.info(host);
      // Sin PIN escrito se prueba con el fijo de la app (servidores con conexión automática).
      final pin = _pin.text.trim().isEmpty ? kAutoPin : _pin.text.trim();
      final token =
          await Api.pair(host, pin, deviceName(ref.read(prefsProvider)));
      await ref
          .read(sessionProvider.notifier)
          .save(Session(host, info.name, token));
    } on PairingException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'No se pudo conectar. Revisa la IP y el firewall.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final found = ref.watch(discoveryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Conectar al servidor'), actions: [
        IconButton(
            icon: const Icon(Icons.radar),
            tooltip: 'Buscar servidores',
            onPressed: () {
              _touched = false;
              ref.invalidate(discoveryProvider);
              _auto();
            }),
      ]),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Row(children: [
          if (_searching)
            const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            const Icon(Icons.lock_outline, size: 18),
          const SizedBox(width: 12),
          Expanded(
              child: Text(
                  _notice ??
                      (_searching
                          ? 'Buscando tu servidor en la red…'
                          : 'Conectando…'),
                  style: const TextStyle(fontSize: 15))),
        ]),
        const SizedBox(height: 20),
        found.when(
          loading: () => const SizedBox(),
          error: (_, __) => const Text('No se pudo buscar en la red.'),
          data: (list) => list.isEmpty
              ? const Text(
                  'Si no aparece, comprueba que el servidor esté encendido y en la misma red. '
                  'También puedes escribir su IP.')
              : Wrap(spacing: 8, children: [
                  for (final s in list)
                    ActionChip(
                      avatar: const Icon(Icons.dns, size: 18),
                      label: Text('${s.info.name}  ${s.address}'),
                      onPressed: () => setState(() {
                        _touched = true;
                        _host.text = s.address;
                      }),
                    ),
                ]),
        ),
        const SizedBox(height: 16),
        TvTextEntry(
            child: TextField(
          controller: _host,
          keyboardType: TextInputType.url,
          onChanged: (_) => _touched = true,
          decoration: const InputDecoration(
              labelText: 'IP del servidor (el puerto es opcional)',
              hintText: '192.168.1.20'),
        )),
        const SizedBox(height: 12),
        TvTextEntry(
            child: TextField(
          controller: _pin,
          keyboardType: TextInputType.number,
          maxLength: 6,
          onChanged: (_) => _touched = true,
          decoration: const InputDecoration(
              labelText: 'PIN (solo si el servidor lo pide)'),
          onSubmitted: (_) => _pair(),
        )),
        FilledButton(
            onPressed: _busy ? null : _pair,
            child: Text(_busy ? 'Conectando...' : 'Conectar')),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.redAccent))),
      ]),
    );
  }
}

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen(
      {super.key,
      required this.api,
      required this.item,
      this.local,
      this.resume,
      this.party,
      this.settings = const PlayerSettings()});
  final Api api;
  final VideoItem item;

  /// Con qué posición arranca. Si es null se deduce de [item] / [local].
  final ResumeInfo? resume;

  /// Ajustes de reproducción que da la app.
  final PlayerSettings settings;

  /// Si se abre para unirse a una sala de "ver juntos".
  final PartyJoin? party;

  /// Copia descargada: se reproduce desde el dispositivo, sin usar el servidor.
  final DownloadEntry? local;
  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

enum _Skip { none, intro, recap, next }

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  Timer? _timer;
  StreamSubscription<String>? _errSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<Map<String, dynamic>>? _cmdSub;
  Timer? _stateTimer;
  late final RemoteNotifier _remote;
  late final DownloadsNotifier _dl;
  late final ProgressSync _sync;
  ScaffoldMessengerState? _messenger;
  VideoDetail? _detail;
  int? _quality; // null = original (Direct Play)
  int _audio = 0; // solo se usa al transcodificar
  bool _ready = false; // no guardar progreso hasta haber retomado la posición
  int _openGen =
      0; // número de apertura: descarta una que quedó superada (otro capítulo...)
  // Si no se pudo volver a donde se había dejado, aquí queda esa posición y NO se guarda
  // nada por debajo de ella: así empezar en 0 por un fallo no borra el progreso anterior.
  int? _resumeGuardMs;
  DateTime? _guardSince;
  // Para detectar que mpv vuelve a 0 por su cuenta DESPUÉS de haber reanudado bien.
  int _lastPosMs = 0;
  DateTime? _noRegressUntil;
  // Respuesta tardía del servidor cuando se arrancó con la posición de la lista.
  Future<({int positionMs, int watchedMs})?>? _lateServer;
  bool _inPip = false;
  // Tapa negra mientras se salta al punto de reanudación: oculta el instante en 0.
  bool _covering = false;
  void _cover(bool v) {
    if (mounted && _covering != v) setState(() => _covering = v);
  }

  StreamSubscription<bool>? _pipSub;
  StreamSubscription<Duration>? _posSub;
  PartyController?
      _party; // "ver juntos": sincroniza este reproductor con una sala
  bool _partySheetShown = false;
  String?
      _extSub; // id del subtítulo externo activo (null = ninguno o uno incrustado)
  double _subDelay = 0, _audioDelay = 0; // s; se reinician con cada video

  Api get _api => widget.api;
  PlayerSettings get _cfg => widget.settings;
  // La copia descargada puede cambiar sin cerrar el reproductor ("Siguiente episodio").
  late DownloadEntry? _local = widget.local;
  bool get _isLocal => _local != null;
  // El capítulo actual puede cambiar sin cerrar el reproductor (botón "Siguiente episodio").
  late VideoItem _item = widget.item;
  String get _id => _item.id;

  /// En móvil el reproductor va a pantalla completa y en horizontal.
  bool get _mobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    Sfx.pushPlayer(); // con el video en pantalla callan los sonidos de navegación
    WidgetsBinding.instance.addObserver(this);
    if (_mobile) {
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _errSub = _player.stream.error.listen(_onError);
    // Al pausar o terminar se guarda al instante (no esperamos al temporizador).
    _playingSub = _player.stream.playing.listen((p) {
      if (!p) _save();
    });
    _completedSub = _player.stream.completed.listen((c) {
      if (c) _save();
    });
    _remote = ref.read(remoteProvider.notifier);
    _dl = ref.read(downloadsProvider.notifier);
    _sync = ref.read(progressSyncProvider);
    unawaited(BookPlayback.stop());
    NativeBridge.setPipEnabled(true);
    _pipSub = NativeBridge.pipChanges.listen((v) {
      if (mounted) setState(() => _inPip = v);
    });
    _cmdSub = _remote.commands.listen(_onCommand);
    _party = PartyController(
      player: _player,
      remote: _remote,
      myId: () => ref.read(remoteProvider).myId,
      ready: () => _ready,
      videoId: () => _id,
      title: () => _titleLine,
      switchTo: _switchTo,
      toast: (t) => _messenger?.showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          content: Text(t))),
    )..addListener(() {
        if (!mounted) return;
        setState(() {});
        // Sala recién creada desde la pestaña Sala: se abre la hoja para invitar a gente.
        if (!_partySheetShown &&
            (_party?.active ?? false) &&
            widget.party?.createControl != null) {
          _partySheetShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openParty();
          });
        }
      });
    final pj = widget.party;
    if (pj?.room != null) {
      _party!.joinRoom(pj!.room!);
    } else if (pj?.createControl != null) {
      _party!.createWhenReady(pj!.createControl!);
    }
    _posSub = _player.stream.position.listen(_onPosition);
    _stateTimer = Timer.periodic(const Duration(seconds: 2), (_) => _publish());
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _save());
    _start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
  }

  /// Si la app pasa a segundo plano (o se cierra desde recientes) el progreso ya está guardado.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _save();
  }

  /// Abre el video donde se dejó, como Netflix.
  /// [fromStart]: empezar en 0 sin reanudar (botón "Siguiente episodio").
  /// La posición inicial la aporta [PlayerScreen.resume]; solo se consulta al servidor si esa
  /// posición puede estar desfasada, y con un margen de tiempo corto.
  Future<void> _start({bool fromStart = false}) async {
    if (_isLocal) {
      // Copia descargada: la ficha y la posición salen del dispositivo, no del servidor.
      final cur = ref.read(downloadsProvider)[_local!.id] ?? _local!;
      _detail = cur.detail;
      _loadSegments(); // solo busca el siguiente capítulo descargado
      final r = widget.resume;
      var pos = fromStart || (r?.fromStart ?? false)
          ? 0
          : (r != null && r.source == ResumeSource.pending
              ? r.positionMs
              : cur.positionMs);
      if (!fromStart && !(r?.fromStart ?? false)) {
        // Visto por streaming y aún sin subir: es más reciente que lo guardado en la copia.
        final pt = _sync.pendingTs(_id);
        final pp = _sync.pendingPosition(_id);
        if (pt != null && pp != null && pt > cur.watchedMs) pos = pp;
      }
      await _open(pos, first: true);
      return;
    }
    _loadSegments(); // en segundo plano; no retrasa el inicio
    final info = fromStart
        ? const ResumeInfo.start()
        : (widget.resume ?? ResumeInfo.fromItem(widget.item));
    var resumeMs = 0;
    if (!info.fromStart) {
      // Ficha (pistas, subtítulos) y posición se piden a la vez, cada una con su tope.
      final detailF = _api
          .detail(_id)
          .timeout(const Duration(seconds: 6))
          .then<VideoDetail?>((d) => d)
          .catchError((_) => null);
      resumeMs = await _resumePositionMs(info);
      if (!mounted) return;
      final d = await detailF.timeout(_cfg.detailBudget, onTimeout: () => null);
      if (mounted && d != null) setState(() => _detail = d);
      if (d == null) {
        // La ficha llega tarde: se aplica cuando llegue, sin retrasar el video.
        detailF.then((late) {
          if (mounted && late != null && _detail == null) {
            setState(() => _detail = late);
          }
        });
      }
    }
    if (!mounted) return;
    final lateF = _lateServer;
    _lateServer = null;
    final id = _id;
    await _open(resumeMs, first: true);
    if (lateF != null) unawaited(_applyLateServer(lateF, resumeMs, id));
  }

  /// Se arrancó con la posición de la lista porque el servidor no respondió a tiempo. Si
  /// responde después con otra muy distinta (p. ej. se vio en otro dispositivo) y aún no se
  /// ha avanzado, se salta ahí.
  Future<void> _applyLateServer(Future<({int positionMs, int watchedMs})?> fut,
      int usedMs, String id) async {
    final r = await fut;
    if (r == null || !mounted || id != _id || _isLocal) return;
    if (_sync.pendingPosition(id) != null) return; // lo de aquí es más reciente
    if ((r.positionMs - usedMs).abs() < 15000) return;
    final pos = _player.state.position.inMilliseconds;
    if (pos > usedMs + 30000)
      return; // ya se ha visto un buen rato desde donde arrancó
    final t = _resumeTarget(r.positionMs, _durMs > 0 ? _durMs : null, true);
    if (t == null) return;
    debugPrint(
        '[reanudar] $id respuesta tardía del servidor=${r.positionMs} (usado=$usedMs)');
    _resumeGuardMs = null;
    final ok = await _confirmPosition(t,
        seekFirst: true, superseded: () => !mounted || id != _id);
    if (ok && mounted && id == _id) _announceResume(t);
  }

  /// Dónde se dejó este video. Por orden de fiabilidad:
  ///  1) lo anotado en este dispositivo que aún no llegó al servidor (lo más reciente);
  ///  2) la posición que da quien abre el reproductor; si es "fresca" se usa ya, y si viene
  ///     de una lista se contrasta con el servidor durante [PlayerSettings.serverCheckBudget];
  ///  3) si no hay nada fiable, el servidor con un par de intentos.
  Future<int> _resumePositionMs(ResumeInfo info) async {
    _lateServer = null;
    final pending = _sync.pendingPosition(_id);
    debugPrint(
        '[reanudar] $_id pendiente_local=$pending dado=${info.positionMs} (${info.source.name})');
    final offline = ref.read(serverOfflineProvider);
    if (pending != null) {
      // Lo anotado aquí gana, SALVO que otro dispositivo haya guardado algo más reciente
      // después (un pendiente que no logra subirse no debe tapar lo que se vio en otro lado).
      if (offline) return pending;
      final r = await _api
          .progressOf(_id, timeout: _cfg.serverCheckBudget)
          .timeout(_cfg.serverCheckBudget, onTimeout: () => null);
      final ts = _sync.pendingTs(_id) ?? 0;
      final mine = math.max(ts, _sync.lastSentAt(_id));
      // Margen para el desfase entre el reloj del servidor y el de este dispositivo.
      if (r != null && r.watchedMs > mine + 15000) {
        debugPrint(
            '[reanudar] $_id otro dispositivo más reciente: ${r.positionMs}');
        _sync.discardPending(
            _id); // si se subiera después, pisaría lo más reciente
        return r.positionMs;
      }
      return pending;
    }
    if (info.source == ResumeSource.fresh ||
        info.source == ResumeSource.pending) {
      return info.positionMs;
    }
    final fallback = info.positionMs;
    // Una sola petición: si responde dentro del margen manda su valor (puede venir de otro
    // dispositivo); si no, se arranca ya con lo de la lista y la petición sigue en curso para
    // corregir al llegar ([_applyLateServer]).
    final f = _api.progressOf(_id, timeout: const Duration(seconds: 6));
    final r = await f.timeout(_cfg.serverCheckBudget, onTimeout: () => null);
    debugPrint('[reanudar] $_id servidor=${r?.positionMs}');
    if (r != null) return r.positionMs;
    if (!mounted) return 0;
    if (offline) return fallback;
    if (fallback > 0) {
      _lateServer = f;
      return fallback;
    }
    // Sin dato de la lista ni respuesta rápida: se espera la misma petición un rato más.
    final r2 =
        await f.timeout(const Duration(seconds: 5), onTimeout: () => null);
    return r2?.positionMs ?? fallback;
  }

  /// Duración conocida por la ficha (la calcula el servidor al sondear el archivo).
  int? get _knownDurationMs {
    final d = _item.durationMs ??
        _detail?.item.durationMs ??
        (_item.id == widget.item.id ? widget.resume?.durationMs : null);
    return (d != null && d > 0) ? d : null;
  }

  /// Duración con la que decidir "ya terminado". Transcodificando, la del reproductor puede
  /// ser parcial; la de la ficha es fiable.
  int get _durMs {
    final known = _knownDurationMs ?? 0;
    final player = _player.state.duration.inMilliseconds;
    if (_quality != null && known > 0) return known;
    return player > 0 ? player : known;
  }

  /// A dónde saltar para reanudar, o null si no toca (poca cosa vista o ya terminado).
  Duration? _resumeTarget(int resumeMs, int? durMs, bool first) {
    if (resumeMs <= _cfg.minResumeMs) return null;
    // Un video ya terminado (>95 %) empieza de nuevo desde el principio.
    if (durMs != null && durMs > 0 && resumeMs >= durMs * _cfg.finishedFraction)
      return null;
    // Como Netflix: retrocede unos segundos para recordar la escena.
    final ms = first ? resumeMs - _cfg.rewindMs : resumeMs;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  Future<void> _open(int resumeMs, {bool first = false}) async {
    final gen = ++_openGen;
    bool superseded() => !mounted || gen != _openGen;
    _ready = false;
    _resumeGuardMs = null;
    _guardSince = null;

    // 1) A dónde saltar. Si la ficha ya trae la duración se decide antes de abrir; si no,
    //    se espera a que el reproductor la descubra.
    final known = _knownDurationMs;
    var target = _resumeTarget(resumeMs, known, first);
    debugPrint(
        '[reanudar] ${_item.id} guardado=${resumeMs}ms dur=${known}ms destino=${target?.inMilliseconds}ms');

    final url = _isLocal
        ? _dl.videoFile(_local!).path
        : _quality == null
            ? _api.streamUrl(_id)
            : _api.hlsUrl(_id, _quality!, _audio);
    _lastPosMs = 0;
    // El punto de inicio se da al abrir (mpv "start"): evita el salto posterior, que a veces
    // se perdía y dejaba el video en 0. Si no se respeta, [_confirmPosition] reintenta.
    final startedAt = target;
    await _player.open(
        Media(url,
            httpHeaders: _isLocal ? null : _api.authHeaders, start: startedAt),
        play: false);
    if (superseded()) return;
    final vol =
        await _applyVolume(); // volumen recordado (con el extra de hasta 150 %)
    _extSub = null;
    _subDelay = _audioDelay = 0;
    await _setMpv('sub-delay', '0');
    await _setMpv('audio-delay', '0');
    if (_cfg.rememberTracks)
      await _applyRememberedTracks(); // audio, subtítulos y sincronía
    if (superseded()) return;

    var unresolved = false; // había algo que reanudar pero no se pudo decidir
    if (resumeMs > _cfg.minResumeMs && known == null) {
      try {
        if (_player.state.duration <= Duration.zero) {
          await _player.stream.duration
              .firstWhere((d) => d > Duration.zero)
              .timeout(const Duration(seconds: 15));
        }
        target = _resumeTarget(
            resumeMs, _player.state.duration.inMilliseconds, first);
      } catch (_) {
        unresolved = true; // sin duración no se sabe si estaba terminado
      }
    }
    if (superseded()) return;
    // Se arrancó en el punto pero resulta que el video ya estaba terminado: desde el principio.
    if (target == null && startedAt != null) {
      await _player.seek(Duration.zero);
    }

    // 2) Reproducir y comprobar que de verdad se está en el punto. Un salto hecho antes de
    //    que el reproductor arranque se pierde a veces (y el video empieza en 0), así que se
    //    verifica la posición y se reintenta. Si hubo que saltar a mano se silencia mientras
    //    tanto para no oír el inicio.
    var resumed = target == null;
    final silent = target != null;
    if (silent) {
      _cover(true);
      await _player.setVolume(0);
    }
    try {
      // En una sala, quien reproduce es la sala (ver PartyController.onOpened).
      if (_cfg.autoPlay && !(_party?.active ?? false)) await _player.play();
      if (target != null) {
        // Con "start" ya debería estar ahí: se comprueba primero y solo se salta si no.
        resumed = await _confirmPosition(target,
            seekFirst: startedAt == null, superseded: superseded);
      }
    } finally {
      if (silent) {
        await _player.setVolume(vol);
        // Un instante para que se pinte ya el fotograma del punto antes de destapar.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (gen == _openGen) _cover(false);
      }
    }
    if (superseded()) return;

    debugPrint(
        '[reanudar] ${_item.id} reanudado=$resumed pos=${_player.state.position.inMilliseconds}ms');
    // 3) No se logró volver al punto: se avisa y se protege lo guardado.
    if (unresolved || (target != null && !resumed)) {
      final lost = target ?? Duration(milliseconds: resumeMs);
      _resumeGuardMs = lost.inMilliseconds;
      _guardSince = DateTime.now();
      _announceResumeFailed(lost);
    }
    // 4) Reanudado bien: se sigue protegiendo lo guardado por si mpv vuelve a 0 más tarde
    //    (ver [_onPosition]).
    _lastPosMs = _player.state.position.inMilliseconds;
    _ready = true;
    _party?.onOpened();
    if (first && resumed && target != null) _announceResume(target);
  }

  /// Espera a que la reproducción esté en [t] (±5 s) y, si no, vuelve a saltar, con esperas
  /// cada vez más largas (redes lentas o archivos grandes tardan en dejar saltar).
  Future<bool> _confirmPosition(Duration t,
      {required bool seekFirst, required bool Function() superseded}) async {
    bool near() =>
        (_player.state.position - t).abs() < const Duration(seconds: 5);
    // Un salto antes de que mpv conozca la duración se pierde: se espera a tenerla.
    try {
      if (_player.state.duration <= Duration.zero) {
        await _player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 4));
      }
    } catch (_) {}
    for (var i = 0; i < 6 && !superseded(); i++) {
      if (seekFirst || i > 0) await _player.seek(t);
      var reached = near();
      if (!reached) {
        try {
          await _player.stream.position
              .firstWhere((_) => near())
              .timeout(Duration(milliseconds: 1200 + 800 * i));
          reached = true;
        } catch (_) {}
      }
      if (!reached) continue;
      // mpv a veces vuelve a 0 justo después de saltar: se comprueba que se mantiene.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (superseded()) return false;
      if (near()) return true;
    }
    return false;
  }

  /// "Reintentar" del aviso: vuelve a saltar a la posición que se había guardado.
  Future<void> _retryResume() async {
    final ms = _resumeGuardMs;
    if (ms == null || !mounted) return;
    final dur = _durMs;
    if (dur > 0 && ms >= dur * _cfg.finishedFraction) {
      _resumeGuardMs = null; // estaba terminado: no hay nada que retomar
      return;
    }
    final t =
        Duration(milliseconds: ms - _cfg.rewindMs < 0 ? 0 : ms - _cfg.rewindMs);
    final ok =
        await _confirmPosition(t, seekFirst: true, superseded: () => !mounted);
    if (ok && mounted) {
      _resumeGuardMs = null;
      _announceResume(t);
    }
  }

  /// "Desde el principio": se acepta empezar en 0 y deja de protegerse lo anterior.
  void _startOver() {
    _resumeGuardMs = null;
    _guardSince = null;
    _noRegressUntil = DateTime.now().add(const Duration(seconds: 3));
    _player.seek(Duration.zero);
  }

  void _announceResumeFailed(Duration at) {
    final m = _messenger;
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 12),
      content: Text('No se pudo retomar en ${_fmt(at)}.'),
      action: SnackBarAction(label: 'Reintentar', onPressed: _retryResume),
    ));
  }

  // Volumen. Sin normalización: cada video suena tal como está grabado (100 %). Como en VLC,
  // se puede subir un extra de hasta [kMaxVolume] % (+50 %) desde los controles (slider de
  // volumen o las flechas arriba/abajo en escritorio).
  // El volumen elegido se recuerda entre videos.
  static const _kVolKey = 'player_volume';

  double get _savedVolume =>
      (ref.read(prefsProvider).getDouble(_kVolKey) ?? kDefaultVolume)
          .clamp(0.0, kMaxVolume)
          .toDouble();

  void _saveVolume(double v) => ref.read(prefsProvider).setDouble(_kVolKey, v);

  /// Fija el tope de mpv en [kMaxVolume] y aplica el volumen recordado. Devuelve el volumen (%)
  /// que quedó puesto, para restaurarlo tras el seek inicial.
  Future<double> _applyVolume() async {
    try {
      final native = _player.platform as dynamic; // NativePlayer (mpv)
      await native.setProperty(
          'volume-max', '${kMaxVolume.toInt()}'); // por defecto mpv: 130
    } catch (_) {}
    final v = (widget.settings.volume ?? _savedVolume)
        .clamp(0.0, kMaxVolume)
        .toDouble();
    try {
      await _player.setVolume(v);
    } catch (_) {
      return _player.state.volume;
    }
    return v;
  }

  void _announceResume(Duration at) {
    final m = _messenger;
    if (m == null) return;
    final w = MediaQuery.of(context).size.width;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.black,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Colors.white24)),
      // Compacto, abajo a la izquierda y por encima de la barra de progreso.
      margin: EdgeInsets.fromLTRB(24, 0, w > 480 ? w - 24 - 400 : 24, 64),
      padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
      dismissDirection:
          DismissDirection.horizontal, // se cierra deslizando a los lados
      duration: const Duration(seconds: 6),
      content: Row(children: [
        Expanded(
            child: Text('Reanudando desde ${_fmt(at)}',
                style: const TextStyle(color: Colors.white, fontSize: 13))),
        TextButton(
            style: TextButton.styleFrom(
                foregroundColor: Colors.lightBlueAccent,
                visualDensity: VisualDensity.compact),
            onPressed: () {
              _startOver();
              m.hideCurrentSnackBar();
            },
            child: const Text('Desde el principio',
                style: TextStyle(fontSize: 13))),
        IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.white70),
            visualDensity: VisualDensity.compact,
            tooltip: 'Cerrar',
            onPressed: () => m.hideCurrentSnackBar()),
      ]),
    ));
  }

  static String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  /// Cambia entre original y transcodificado conservando la posición actual.
  Future<void> _reopen(int? quality, int audio) async {
    var pos = _player.state.position.inMilliseconds;
    // Si aún no se había logrado volver al punto guardado (posición en 0 por un fallo),
    // se conserva ESE punto: no se reabre en 0 ni se pierde la protección del progreso.
    final guard = _resumeGuardMs;
    if (guard != null && pos < guard - 5000) pos = guard;
    setState(() {
      _quality = quality;
      _audio = audio;
    });
    await _open(pos);
  }

  void _onError(String e) {
    // Solo ofrecer transcodificar si el original ni siquiera llegó a arrancar.
    if (!mounted || _quality != null) return;
    if (_player.state.playing || _player.state.position > Duration.zero) return;
    if (_isLocal) {
      // Sin servidor no hay transcodificación: solo avisar.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'No se pudo reproducir el archivo descargado. Elimínalo y vuelve a descargarlo.')));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:
          const Text('No se pudo reproducir el original. ¿Transcodificar?'),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
          label: 'Transcodificar', onPressed: () => _reopen(720, _audio)),
    ));
  }

  void _onCommand(Map<String, dynamic> m) {
    switch (m['action']) {
      case 'play':
        _player.play();
      case 'pause':
        _player.pause();
      case 'toggle':
        _player.playOrPause();
      case 'seekBy':
        _player.seek(_player.state.position +
            Duration(milliseconds: (m['deltaMs'] as num).toInt()));
      case 'seekTo':
        _player.seek(Duration(milliseconds: (m['positionMs'] as num).toInt()));
      case 'stop':
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  void _publish() {
    _remote.publishState({
      'videoId': _id,
      'title': _item.title,
      'positionMs': _player.state.position.inMilliseconds,
      'durationMs': _player.state.duration.inMilliseconds,
      'playing': _player.state.playing,
    });
  }

  void _save() {
    if (!_ready) return;
    final pos = _player.state.position;
    final dur = _durMs;
    // Menos de 5 s no es "haber visto" nada (y justo ahí está el 0 de un salto fallido).
    if (pos < const Duration(seconds: 5) || dur <= 0) return;
    final guard = _resumeGuardMs;
    if (guard != null) {
      final since = _guardSince ?? DateTime.now();
      if (pos.inMilliseconds >= guard - 5000) {
        _resumeGuardMs =
            null; // ya se alcanzó (o se pasó) lo que había guardado
      } else if (_player.state.playing &&
          DateTime.now().difference(since) > const Duration(minutes: 3)) {
        _resumeGuardMs =
            null; // 3 min viéndolo desde el principio: es a propósito
      } else {
        return; // no pisar el progreso anterior con una posición más baja por un fallo
      }
    }
    final done = pos.inMilliseconds > dur * 0.95;
    // Al terminar se guarda la duración completa: cuenta como visto (>95 %), deja de salir en
    // "Continuar viendo" y la serie salta al capítulo siguiente.
    final ms = done ? dur : pos.inMilliseconds;
    if (_isLocal) {
      // Se guarda en el dispositivo y se sube al servidor en cuanto esté disponible.
      _dl.setPosition(_id, ms);
      return;
    }
    // Se anota aquí al instante y se sube en segundo plano con reintentos (ver progress_sync).
    debugPrint('[reanudar] guardar $_id ${ms}ms');
    _sync.record(_id, ms);
    _dl.mirrorPosition(
        _id, ms); // si ese video también está descargado, que no quede viejo
  }

  /// Fija una propiedad de mpv. Devuelve false si no se pudo (p. ej. plataforma sin mpv).
  Future<bool> _setMpv(String name, String value) async {
    try {
      await (_player.platform as dynamic).setProperty(name, value);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setSubDelay(double v) {
    _subDelay = v;
    _remember({'sd': v});
    _setMpv('sub-delay', v.toString()); // + = subtítulos más tarde
  }

  void _setAudioDelay(double v) {
    _audioDelay = v;
    _remember({'ad': v});
    _setMpv('audio-delay',
        (-v).toString()); // en mpv el signo va al revés: + aquí = audio más tarde
  }

  // ---------- pistas recordadas ----------
  // Lo que eliges en el menú de audio y subtítulos (pista, subtítulo y sincronía) se guarda por
  // video, y en las series también por serie: el siguiente capítulo abre con el mismo idioma.
  // No se guarda el id de la pista (cambia de un archivo a otro) sino su idioma, título y posición.
  String get _trkKey => 'trk:v:$_id';
  String? get _trkShowKey =>
      _item.showId == null ? null : 'trk:s:${_item.showId}';

  static bool _realId(String id) => id != 'auto' && id != 'no';

  static String? _norm(Object? o) {
    final t = '${o ?? ''}'.trim().toLowerCase();
    return (t.isEmpty || t == 'und' || t == 'unk') ? null : t;
  }

  Map<String, dynamic> _readTrk(String key) {
    try {
      final raw = ref.read(prefsProvider).getString(key);
      if (raw == null) return {};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  /// Guarda un cambio ('a' audio, 's' subtítulos, 'ad'/'sd' sincronía) para este video y,
  /// en series, la pista elegida también para la serie (la sincronía solo es del video).
  void _remember(Map<String, dynamic> change) {
    final p = ref.read(prefsProvider);
    void put(String key, Map<String, dynamic> c) {
      final m = _readTrk(key)..addAll(c);
      p.setString(key, jsonEncode(m));
    }

    put(_trkKey, change);
    final sk = _trkShowKey;
    if (sk != null) {
      final c = {
        for (final e in change.entries)
          if (e.key == 'a' || e.key == 's') e.key: e.value
      };
      if (c.isNotEmpty) put(sk, c);
    }
  }

  Map<String, dynamic> _descAudio(AudioTrack t) {
    final list =
        _player.state.tracks.audio.where((x) => _realId(x.id)).toList();
    return {
      'lang': t.language,
      'title': t.title,
      'i': list.indexWhere((x) => x.id == t.id)
    };
  }

  Map<String, dynamic> _descSub(SubtitleTrack t) {
    final list =
        _player.state.tracks.subtitle.where((x) => _realId(x.id)).toList();
    return {
      'k': 'emb',
      'lang': t.language,
      'title': t.title,
      'i': list.indexWhere((x) => x.id == t.id)
    };
  }

  /// Índice de la pista de [list] que mejor encaja con lo guardado: idioma y título, luego
  /// solo idioma y, únicamente si es el mismo video, la misma posición. -1 si ninguna.
  static int _matchTrack(List<({String? lang, String? title})> list, Map d,
      {required bool allowIndex}) {
    final lang = _norm(d['lang']), title = _norm(d['title']);
    if (lang != null || title != null) {
      for (var k = 0; k < list.length; k++) {
        if (_norm(list[k].lang) == lang && _norm(list[k].title) == title) {
          return k;
        }
      }
      if (lang != null) {
        for (var k = 0; k < list.length; k++) {
          if (_norm(list[k].lang) == lang) return k;
        }
      }
    }
    final i = d['i'];
    if (allowIndex && i is int && i >= 0 && i < list.length) return i;
    return -1;
  }

  /// Ruta o URL de un subtítulo externo, o null si no está disponible.
  String? _extUri(TrackInfo t, bool direct) {
    if (_isLocal) {
      // Subtítulos externos descargados junto con el video.
      final path = _dl.subtitlePath(_local!, t.id);
      return (t.external && File(path).existsSync()) ? path : null;
    }
    if (t.external || (!direct && t.text)) return _api.subtitleUrl(_id, t.id);
    return null;
  }

  /// Al abrir un video, repone lo que se eligió la vez anterior (si hay algo guardado).
  Future<void> _applyRememberedTracks() async {
    final v = _readTrk(_trkKey);
    final sk = _trkShowKey;
    final sh = sk == null ? const <String, dynamic>{} : _readTrk(sk);
    final a = v['a'] ?? sh['a'], aFromShow = v['a'] == null;
    final s = v['s'] ?? sh['s'], sFromShow = v['s'] == null;
    final sd = (v['sd'] as num?)?.toDouble();
    final ad = (v['ad'] as num?)?.toDouble();
    if (a == null && s == null && sd == null && ad == null) return;

    if (sd != null) {
      _subDelay = sd;
      await _setMpv('sub-delay', sd.toString());
    }
    if (ad != null) {
      _audioDelay = ad;
      await _setMpv('audio-delay', (-ad).toString());
    }

    // En transcodificado el servidor elige el audio y los subtítulos incrustados no existen.
    final direct = _quality == null;
    final needEmbedded = direct && (a is Map || (s is Map && s['k'] == 'emb'));
    if (needEmbedded) {
      // La lista de pistas llega un instante después de abrir el archivo.
      bool ready(Tracks t) =>
          t.audio.any((x) => _realId(x.id)) ||
          t.subtitle.any((x) => _realId(x.id));
      if (!ready(_player.state.tracks)) {
        try {
          await _player.stream.tracks
              .firstWhere(ready)
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
      if (!mounted) return;
    }

    try {
      if (direct && a is Map) {
        final list =
            _player.state.tracks.audio.where((x) => _realId(x.id)).toList();
        final k = _matchTrack(
            [for (final x in list) (lang: x.language, title: x.title)], a,
            allowIndex: !aFromShow);
        if (k >= 0) await _player.setAudioTrack(list[k]);
      }
      if (s is Map) {
        final kind = s['k'];
        if (kind == 'off') {
          _extSub = null;
          await _player.setSubtitleTrack(SubtitleTrack.no());
        } else if (kind == 'emb' && direct) {
          final list = _player.state.tracks.subtitle
              .where((x) => _realId(x.id))
              .toList();
          final k = _matchTrack(
              [for (final x in list) (lang: x.language, title: x.title)], s,
              allowIndex: !sFromShow);
          if (k >= 0) {
            _extSub = null;
            await _player.setSubtitleTrack(list[k]);
          }
        } else if (kind == 'ext') {
          for (final t in _detail?.subtitles ?? const <TrackInfo>[]) {
            if (!(t.id == s['id'] && !sFromShow) && t.label != s['label']) {
              continue;
            }
            final u = _extUri(t, direct);
            if (u == null) continue;
            _extSub = t.id;
            await _player
                .setSubtitleTrack(SubtitleTrack.uri(u, title: t.label));
            break;
          }
        }
      }
    } catch (_) {}
  }

  /// Panel lateral con pestañas de Audio, Subtítulos y Calidad (ver track_menu.dart).
  Future<String?> _mpvGet(String name) async {
    try {
      return (await (_player.platform as dynamic).getProperty(name))
          ?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _menu({int initial = 1}) async {
    // Si la ficha no llegó al abrir (red lenta), se intenta de nuevo ahora.
    if (_detail == null && !_isLocal) {
      try {
        final d = await _api.detail(_id).timeout(const Duration(seconds: 4));
        if (mounted) setState(() => _detail = d);
      } catch (_) {}
    }
    // Se lee de mpv qué pista suena de verdad: el estado de media_kit se queda en "auto"
    // mientras no se elija una a mano y entonces ninguna aparecía marcada.
    final aid = await _mpvGet('aid');
    final sid = await _mpvGet('sid');
    if (!mounted) return;
    final tracks = _player.state.tracks;
    final cur = _player.state.track;
    final audioId = (aid == null || aid == 'auto') ? cur.audio.id : aid;
    final subId = (sid == null || sid == 'auto') ? cur.subtitle.id : sid;
    final direct = _quality == null;

    final audio = <MenuOption>[];
    if (direct) {
      for (final t
          in tracks.audio.where((t) => t.id != 'auto' && t.id != 'no')) {
        final (label, detail) = trackText(t.id, t.title, t.language);
        audio.add(MenuOption(label, audioId == t.id, () {
          _player.setAudioTrack(t);
          _remember({'a': _descAudio(t)});
        }, detail: detail));
      }
    } else {
      for (final t in _detail?.audio ?? const <TrackInfo>[]) {
        audio.add(MenuOption(t.label, '$_audio' == t.id,
            () => _reopen(_quality, int.parse(t.id))));
      }
    }

    final subs = <MenuOption>[
      MenuOption('Desactivados',
          _extSub == null && (subId == 'no' || subId == 'false'), () {
        _extSub = null;
        _player.setSubtitleTrack(SubtitleTrack.no());
        _remember({
          's': {'k': 'off'}
        });
      }),
    ];
    if (direct) {
      // En Direct Play, libmpv ya expone las pistas incrustadas (incluidas PGS).
      for (final t
          in tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no')) {
        final (label, detail) = trackText(t.id, t.title, t.language);
        subs.add(MenuOption(label, _extSub == null && subId == t.id, () {
          _extSub = null;
          _player.setSubtitleTrack(t);
          _remember({'s': _descSub(t)});
        }, detail: detail));
      }
    }
    for (final t in _detail?.subtitles ?? const <TrackInfo>[]) {
      final u = _extUri(t, direct);
      if (u == null) continue;
      subs.add(MenuOption(t.label, _extSub == t.id, () {
        _extSub = t.id;
        _player.setSubtitleTrack(SubtitleTrack.uri(u, title: t.label));
        _remember({
          's': {'k': 'ext', 'id': t.id, 'label': t.label}
        });
      }, detail: t.external ? 'Archivo externo' : null));
    }

    // Se espera a que se cierre: en TV los controles no se ocultan mientras está abierto.
    await showTrackMenu(
      context,
      initial: initial, // por defecto Subtítulos, lo que más se cambia
      tv: ref.read(tvModeProvider),
      sections: [
        MenuSection('Audio', Icons.volume_up_rounded, audio,
            emptyText: 'Este video no tiene pistas de audio.',
            delayLabel: 'Sincronía del audio',
            delay: _audioDelay,
            onDelay: _setAudioDelay),
        MenuSection('Subtítulos', Icons.subtitles_rounded, subs,
            delayLabel: 'Retraso de subtítulos',
            delay: _subDelay,
            onDelay: _setSubDelay,
            footerBuilder: (setActive) =>
                SubtitleSizeControl(onActive: setActive)),
        if (!_isLocal)
          // La transcodificación la hace el servidor: no existe en una descarga.
          MenuSection('Calidad', Icons.high_quality_rounded, [
            MenuOption('Original', direct, () => _reopen(null, 0),
                detail: 'Sin transcodificar (Direct Play)'),
            for (final q in [1080, 720, 480])
              MenuOption('${q}p', _quality == q, () => _reopen(q, _audio),
                  detail: 'Transcodificado por el servidor'),
          ]),
      ],
    );
  }

  // ---------- saltar intro / resumen y "Siguiente episodio" ----------
  PlaybackSegments _seg = PlaybackSegments.empty;
  _Skip _btn = _Skip.none;
  int _btnTarget = 0; // a dónde salta "Saltar intro/resumen"
  bool _switching = false;

  Future<void> _loadSegments() async {
    if (_isLocal) {
      // Sin servidor no hay marcas de intro, pero sí "Siguiente episodio" con el
      // siguiente capítulo descargado de la serie.
      final cur = _local!;
      final sid = cur.showId;
      if (sid == null) return;
      final eps = _dl.doneEpisodes(sid);
      final i = eps.indexWhere((e) => e.id == cur.id);
      if (i >= 0 && i + 1 < eps.length) {
        final n = eps[i + 1];
        _seg = PlaybackSegments(
            next: NextEpisode(n.id, n.item.epTitle ?? n.item.title));
      }
      return;
    }
    final id = _id;
    final s = await _api.segments(id);
    if (mounted && id == _id) _seg = s;
  }

  /// Tramo de [l] que contiene [ms]; ignora datos absurdos (muy cortos o fuera de lugar).
  Seg? _active(List<Seg> l, int ms, int dur) {
    for (final s in l) {
      final end = s.endMs ?? dur;
      if (end - s.startMs < 5000) continue;
      if (s.startMs > dur * 0.5 || end - s.startMs > 5 * 60000) continue;
      if (ms >= s.startMs && ms < end - 1500) return s;
    }
    return null;
  }

  /// Cuándo aparece "Siguiente episodio": al empezar los créditos si TheIntroDB los conoce;
  /// si no, se calcula: los últimos ~4 % del capítulo (entre 30 y 90 segundos).
  int? _nextAt(int dur) {
    if (_seg.next == null || dur < 5 * 60000) return null;
    final starts = [
      for (final s in [..._seg.credits, ..._seg.preview])
        if (s.startMs > dur * 0.5 && s.startMs < dur - 5000) s.startMs
    ]..sort();
    if (starts.isNotEmpty) return starts.first;
    final tail = (dur * 0.04).clamp(30000, 90000).toInt();
    return dur - tail;
  }

  void _onPosition(Duration pos) {
    final ms = pos.inMilliseconds, dur = _player.state.duration.inMilliseconds;
    // mpv a veces vuelve al inicio por su cuenta (reconexión, HLS...). Una caída así desde más
    // de un minuto hasta los primeros segundos protege lo guardado: no se pisa con la posición
    // baja (se libera al volver a alcanzarlo o tras 3 min viéndolo desde ahí).
    if (_ready && _resumeGuardMs == null && _lastPosMs > 60000 && ms < 5000) {
      final until = _noRegressUntil;
      if (until == null || DateTime.now().isAfter(until)) {
        debugPrint(
            '[reanudar] $_id volvió a ${ms}ms desde ${_lastPosMs}ms: se protege el progreso');
        _resumeGuardMs = _lastPosMs;
        _guardSince = DateTime.now();
      }
    }
    _lastPosMs = ms;
    var b = _Skip.none;
    var target = 0;
    if (dur > 0 && _ready) {
      final intro = _active(_seg.intro, ms, dur);
      final recap = intro == null ? _active(_seg.recap, ms, dur) : null;
      if (intro != null) {
        b = _Skip.intro;
        target = intro.endMs ?? 0;
      } else if (recap != null) {
        b = _Skip.recap;
        target = recap.endMs ?? 0;
      } else {
        final at = _nextAt(dur);
        if (at != null && ms >= at) b = _Skip.next;
      }
    }
    if (b != _btn || target != _btnTarget) {
      setState(() {
        _btn = b;
        _btnTarget = target;
      });
    }
  }

  /// Pasa al capítulo siguiente dentro del mismo reproductor (sin cerrar la pantalla).
  Future<void> _goNext() async {
    final n = _seg.next;
    if (n == null || _switching) return;
    if (!_isLocal && (_party?.active ?? false)) {
      _party!.requestNext(n.id, n.title); // la sala lo abre en todos a la vez
      return;
    }
    _switching = true;
    if (_isLocal) {
      final e = ref.read(downloadsProvider)[n.id];
      if (e == null || e.state != DlState.done) {
        _switching = false;
        return;
      }
      final dur = _player.state.duration.inMilliseconds;
      if (dur > 0) _dl.setPosition(_id, dur); // el actual cuenta como visto
      _ready = false;
      setState(() {
        _local = e;
        _item = e.item;
        _detail = e.detail;
        _seg = PlaybackSegments.empty;
        _btn = _Skip.none;
      });
      try {
        await _start(fromStart: true);
      } finally {
        _switching = false;
      }
      return;
    }
    try {
      final d = await _api.detail(n.id);
      if (!mounted) return;
      final dur = _durMs;
      if (dur > 0) _sync.record(_id, dur); // el actual cuenta como visto
      _ready = false; // así no se guarda la posición vieja con el id nuevo
      setState(() {
        _item = d.item;
        _detail = d;
        _seg = PlaybackSegments.empty;
        _btn = _Skip.none;
        _audio = 0;
      });
      await _start(
          fromStart: true); // el siguiente siempre empieza desde el principio
    } catch (_) {
    } finally {
      _switching = false;
    }
  }

  /// Abre otro video (el que pasó a reproducir la sala) dentro de este mismo reproductor.
  Future<void> _switchTo(String id) async {
    if (_switching || id == _id || _isLocal) return;
    _switching = true;
    try {
      final d = await _api.detail(id);
      if (!mounted) return;
      final dur = _durMs;
      _save(); // la posición del actual queda guardada antes de cambiar
      if (dur > 0 && _player.state.position.inMilliseconds > dur * 0.8) {
        _sync.record(_id, dur); // lo terminó: cuenta como visto
      }
      _ready = false; // así no se guarda la posición vieja con el id nuevo
      setState(() {
        _item = d.item;
        _detail = d;
        _seg = PlaybackSegments.empty;
        _btn = _Skip.none;
        _audio = 0;
      });
      await _start(fromStart: true);
    } catch (_) {
    } finally {
      _switching = false;
    }
  }

  void _openParty() {
    if (_party != null) showPartySheet(context, _party!);
  }

  Widget _skipButton() {
    final next = _btn == _Skip.next;
    final label = switch (_btn) {
      _Skip.intro => 'Saltar intro',
      _Skip.recap => 'Saltar resumen',
      _ => 'Siguiente episodio',
    };
    return TvButtonFocus(
      radius: 8,
      builder: (_, focused) => FilledButton.icon(
        style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)))
            .copyWith(side: const WidgetStatePropertyAll(BorderSide.none)),
        onPressed: next
            ? _goNext
            : () => _player.seek(Duration(milliseconds: _btnTarget)),
        icon: Icon(next ? Icons.skip_next : Icons.fast_forward,
            color: focused ? const Color(0xFFE50914) : null),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }

  String get _titleLine =>
      _item.isEpisode ? (_item.show ?? _item.title) : _item.title;

  /// Capítulos: "T1 · E3 · Nombre del capítulo". Películas: sin subtítulo.
  String? get _subtitleLine {
    if (!_item.isEpisode) return null;
    final t = _item.epTitle;
    return t == null || t.isEmpty
        ? _item.episodeLabel
        : '${_item.episodeLabel} · $t';
  }

  /// Controles propios (ver player_controls.dart): mismos en móvil y escritorio.
  Widget _controls(VideoState state) {
    final tv = ref.read(tvModeProvider);
    return PlayerControls(
      player: _player,
      title: _titleLine,
      subtitle: _subtitleLine,
      videoState: state,
      onBack: () => Navigator.of(context).maybePop(),
      onMenu: (section) => _menu(initial: section),
      qualityAvailable: !_isLocal,
      onParty: _isLocal ? null : _openParty,
      partyActive: _party?.active ?? false,
      onPip: Platform.isAndroid && !tv ? NativeBridge.enterPip : null,
      onVolumeChanged: _saveVolume,
      tv: tv,
      // En TV el botón de saltar va dentro de los controles, para llegar a él con el mando.
      skip: tv && _btn != _Skip.none ? _skipButton() : null,
    );
  }

  @override
  void dispose() {
    Sfx.popPlayer();
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _errSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _pipSub?.cancel();
    _posSub?.cancel();
    NativeBridge.setPipEnabled(false);
    _cmdSub?.cancel();
    _stateTimer?.cancel();
    _party?.dispose(); // sale de la sala; lo que vio ya se guarda abajo
    _remote.publishState(null);
    _save();
    _messenger?.clearSnackBars();
    _player.dispose();
    if (_mobile) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Al empezar a salir (no cuando acaba la animación) se guarda y se sube el progreso,
      // para que la biblioteca ya lo tenga al aparecer.
      onPopInvoked: (didPop) {
        if (didPop) _save();
      },
      child: _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // Solo los lados: evita la muesca/cámara en horizontal sin recortar arriba ni abajo.
      body: SafeArea(
        top: false,
        bottom: false,
        child: Stack(children: [
          Positioned.fill(
            child: Video(
                controller: _controller,
                controls: _inPip ? NoVideoControls : _controls,
                // Tamaño de subtítulos elegido en el menú del reproductor: se aplica al instante.
                subtitleViewConfiguration: subtitleConfig(ref
                    .watch(settingsProvider.select((s) => s.subtitleScale)))),
          ),
          if (_covering)
            const Positioned.fill(
                child: IgnorePointer(
                    child: ColoredBox(
                        color: Colors.black,
                        child: Center(child: MinimalVideoLoader())))),
          // Botón estilo Netflix, abajo a la derecha, por encima de la barra de controles.
          if (_btn != _Skip.none && !_inPip && !ref.watch(tvModeProvider))
            Positioned(right: 24, bottom: 112, child: _skipButton()),
        ]),
      ),
    );
  }
}

class RemoteScreen extends ConsumerWidget {
  const RemoteScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remote = ref.watch(remoteProvider);
    final ctl = ref.read(remoteProvider.notifier);
    final others = remote.others;
    return Scaffold(
      appBar: AppBar(title: const Text('Control remoto')),
      body: !remote.connected
          ? const Center(child: Text('Sin conexión con el servidor...'))
          : others.isEmpty
              ? const Center(
                  child: Text('No hay otros dispositivos conectados.'))
              : ListView(
                  children: [for (final d in others) _DeviceCard(d, ctl)]),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard(this.d, this.ctl);
  final RemoteDevice d;
  final RemoteNotifier ctl;

  @override
  Widget build(BuildContext context) {
    final s = d.state;
    final pos = (s?['positionMs'] as num?)?.toDouble() ?? 0;
    final dur = (s?['durationMs'] as num?)?.toDouble() ?? 0;
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.tv),
            const SizedBox(width: 8),
            Text(d.name, style: Theme.of(context).textTheme.titleMedium),
          ]),
          const SizedBox(height: 8),
          Text((s?['title'] as String?) ?? 'Sin reproducir',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (s != null && dur > 0)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                    value: (pos / dur).clamp(0.0, 1.0).toDouble())),
          if (s != null)
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                  icon: const Icon(Icons.replay_30),
                  onPressed: () =>
                      ctl.command(d.id, 'seekBy', {'deltaMs': -30000})),
              IconButton(
                  iconSize: 40,
                  icon: Icon(s['playing'] == true
                      ? Icons.pause_circle
                      : Icons.play_circle),
                  onPressed: () => ctl.command(d.id, 'toggle')),
              IconButton(
                  icon: const Icon(Icons.forward_30),
                  onPressed: () =>
                      ctl.command(d.id, 'seekBy', {'deltaMs': 30000})),
              IconButton(
                  icon: const Icon(Icons.stop_circle_outlined),
                  onPressed: () => ctl.command(d.id, 'stop')),
            ]),
        ]),
      ),
    );
  }
}
