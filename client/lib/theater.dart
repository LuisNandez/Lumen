import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import 'age_rating.dart';
import 'audiobooks.dart';
import 'package:shared/audiobook.dart';
import 'api.dart';
import 'core.dart';
import 'downloads.dart';
import 'main.dart' show PlayerScreen, RemoteScreen;
import 'news.dart' show NewsBell;
import 'player_params.dart';
import 'oscars.dart';
import 'remote.dart';
import 'progress_sync.dart';
import 'tv.dart';
import 'sounds.dart';

// ===========================================================================
//  Modo teatro: biblioteca con carátulas, estilo Netflix, y perfiles tipo Plex.
// ===========================================================================

const _bg = Color(0xFF141414);
const _red = Color(0xFFE50914);

/// En TV la ficha de película no pinta la flecha de volver (el mando ya trae la tecla Atrás y
/// la flecha era una parada de foco más). Ponlo en true si la quieres de vuelta.
const _tvShowBack = false;

/// Borde que solo se pinta con foco (aro fino de 2 px). Los botones rellenos o con borde propio
/// lo necesitan: con el aro blanco del tema de TV no se vería (o lo taparía su `side` fijo).
WidgetStateProperty<BorderSide?> _focusSide(Color ring, [BorderSide? idle]) =>
    WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused)
        ? BorderSide(color: ring, width: kFocusWidth)
        : idle);

/// En TV el contenido de las fichas no ocupa todo el ancho: líneas más cortas y fáciles de leer.
/// Salta el foco a [target] sin dejar rastro en el historial de la navegación direccional.
/// Flutter recuerda de dónde vienes para que ▲ tras ▼ "vuelva atrás"; si el foco se mueve a
/// mano sin avisarle, la siguiente flecha en sentido contrario intenta volver a un elemento
/// que ya tiene el foco y parece que no hace nada (hay que pulsar dos veces).
void _tvJump(FocusNode target) {
  final cur = FocusManager.instance.primaryFocus;
  final ctx = cur?.context ?? target.context;
  if (ctx != null) {
    final policy = FocusTraversalGroup.maybeOf(ctx);
    final scopes = <FocusScopeNode>{
      if (cur?.nearestScope != null) cur!.nearestScope!,
      if (target.nearestScope != null) target.nearestScope!,
    };
    for (final sc in scopes) {
      policy?.invalidateScopeData(sc);
    }
  }
  target.requestFocus();
}

/// Instala la política de foco de TV (◀▶ solo dentro de la misma fila) en una pantalla que se
/// abrió con Navigator.push y por tanto queda fuera del grupo de foco del shell.
Widget _tvGroup(bool tv, TvTraversalPolicy policy, Widget child) =>
    tv ? FocusTraversalGroup(policy: policy, child: child) : child;

/// Flecha dirigida: al pulsar [keyId] dentro de [child] se llama a [onKey]; si devuelve true
/// el foco ya se movió y no se hace nada más; si devuelve false, queda el comportamiento
/// normal de las flechas.
class _TvKeyTo extends StatelessWidget {
  const _TvKeyTo(
      {required this.keyId,
      required this.onKey,
      required this.child,
      this.enabled = true});
  final LogicalKeyboardKey keyId;
  final bool Function() onKey;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => enabled
      ? Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, e) {
            if (e is! KeyDownEvent || e.logicalKey != keyId) {
              return KeyEventResult.ignored;
            }
            return onKey() ? KeyEventResult.handled : KeyEventResult.ignored;
          },
          child: child)
      : child;
}

/// Red de seguridad tras saltar el foco a una fila: si un fotograma después el foco no llegó a
/// [rowNode] (y el usuario tampoco lo movió a otro sitio), se enfoca la primera tarjeta montada
/// de esa fila. Así ▲▼ nunca se quedan "atascadas" por un nodo que ya no existe.
void _tvEnsureIn(FocusNode? before, FocusNode rowNode) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (rowNode.hasFocus || FocusManager.instance.primaryFocus != before) {
      return;
    }
    for (final d in rowNode.traversalDescendants) {
      if (tvUsable(d)) {
        _tvJump(d);
        return;
      }
    }
  });
  // Un salto fallido no provoca ningún fotograma: se pide uno para que la comprobación corra.
  WidgetsBinding.instance.scheduleFrame();
}

/// Dueño de los nodos de foco de la ficha de película en TV (Reproducir/Reanudar y la tarjeta
/// del video), que la pantalla de la película (sin estado) no puede guardar.
class _TvMovieNav extends StatefulWidget {
  const _TvMovieNav({required this.builder});
  final Widget Function(BuildContext context, FocusNode play, FocusNode video)
      builder;
  @override
  State<_TvMovieNav> createState() => _TvMovieNavState();
}

class _TvMovieNavState extends State<_TvMovieNav> {
  final _play = FocusNode(debugLabel: 'MoviePlay');
  final _video = FocusNode(debugLabel: 'MovieVideo');
  final _policy = TvTraversalPolicy(); // ◀▶ estrictos por fila (ver ShowScreen)

  @override
  void dispose() {
    _play.dispose();
    _video.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
      policy: _policy, child: widget.builder(context, _play, _video));
}

Widget _tvWidth(bool tv, Widget child) => tv
    ? Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900), child: child))
    : child;

/// Detalle + perfil de un video (se refresca al editar el perfil).
final detailProvider =
    FutureProvider.autoDispose.family<VideoDetail, String>((ref, id) {
  final api = ref.watch(apiProvider);
  if (api == null) throw StateError('Sin sesión');
  return api.detail(id);
});

// ---------- acciones compartidas ----------

/// Reproduce y, al volver, refresca biblioteca y detalle (el progreso cambió).
Future<void> playVideo(BuildContext context, Api api, VideoItem v) async {
  Sfx.play(Snd.entrar);
  final container = ProviderScope.containerOf(context);
  await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              PlayerScreen(api: api, item: v, resume: ResumeInfo.fromItem(v))));
  await container
      .read(progressSyncProvider)
      .settle(); // el último progreso ya subió
  container.invalidate(libraryProvider);
  container.invalidate(detailProvider(v.id));
}

void _playOn(BuildContext context, WidgetRef ref, VideoItem v) {
  final others = ref.read(remoteProvider).others;
  if (others.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay otros dispositivos conectados.')));
    return;
  }
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Reproducir en...',
                style: Theme.of(ctx).textTheme.titleMedium)),
        for (final d in others)
          ListTile(
            leading: const Icon(Icons.tv),
            title: Text(d.name),
            onTap: () {
              Navigator.pop(ctx);
              ref
                  .read(remoteProvider.notifier)
                  .command(d.id, 'open', {'videoId': v.id});
            },
          ),
      ]),
    ),
  );
}

/// Abre el editor de perfil; si hubo cambios, refresca la biblioteca.
Future<void> editProfile(BuildContext context, Api api, String id) async {
  final container = ProviderScope.containerOf(context);
  try {
    final d = await api.detail(id);
    if (!context.mounted) return;
    final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => EditProfileScreen(api: api, detail: d)));
    if (changed == true) {
      container.invalidate(libraryProvider);
      container.invalidate(detailProvider(id));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(errorSnack(errText(e)));
    }
  }
}

/// Busca el título automáticamente por el nombre del archivo.
Future<void> _autoIdentify(BuildContext context, Api api, String id) async {
  final container = ProviderScope.containerOf(context);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Buscando en TMDB...')));
  try {
    await api.autoProfile(id);
    container.invalidate(libraryProvider);
    container.invalidate(detailProvider(id));
    messenger.hideCurrentSnackBar();
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(errorSnack('${errText(e)} Prueba con "Buscar en TMDB".'));
  }
}

Future<void> _searchTmdb(BuildContext context, Api api, VideoItem item) async {
  final container = ProviderScope.containerOf(context);
  final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
          builder: (_) => TmdbSearchScreen(api: api, item: item)));
  if (ok == true) {
    container.invalidate(libraryProvider);
    container.invalidate(detailProvider(item.id));
  }
}

/// Fila "Descargar" del menú de una película; si ya está en la lista, muestra su estado.
Widget _downloadTile(
    BuildContext context, WidgetRef ref, BuildContext sheet, VideoItem v) {
  final e = ref.read(downloadsProvider)[v.id];
  final label = switch (e?.state) {
    null => 'Descargar para ver sin servidor',
    DlState.done => 'Descargada · opciones',
    DlState.downloading => 'Descargando... · opciones',
    DlState.queued => 'En cola · opciones',
    DlState.paused => 'Descarga pausada · opciones',
    DlState.error => 'Descarga interrumpida · opciones',
  };
  return ListTile(
      leading:
          Icon(e?.state == DlState.done ? Icons.download_done : Icons.download),
      title: Text(label),
      onTap: () {
        Navigator.pop(sheet);
        if (e == null) {
          askDownload(context, ref, v);
        } else {
          showDownloadSheet(context, ref, e);
        }
      });
}

void _options(BuildContext context, WidgetRef ref, Api api, VideoItem v) {
  if (v.isShow) {
    _showOptions(context, ref, api, v);
    return;
  }
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
            title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(v.infoLabel,
                maxLines: 1, overflow: TextOverflow.ellipsis)),
        ListTile(
            leading: const Icon(Icons.play_arrow),
            title: Text(v.progress != null ? 'Reanudar' : 'Reproducir'),
            onTap: () {
              Navigator.pop(ctx);
              playVideo(context, api, v);
            }),
        ListTile(
            leading: const Icon(Icons.cast),
            title: const Text('Reproducir en otro dispositivo'),
            onTap: () {
              Navigator.pop(ctx);
              _playOn(context, ref, v);
            }),
        _downloadTile(context, ref, ctx, v),
        /*ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Editar perfil'),
            onTap: () {
              Navigator.pop(ctx);
              editProfile(context, api, v.id);
            }),*/
        if (v.isEpisode)
          ListTile(
              leading: const Icon(Icons.format_list_numbered),
              title: const Text('Ver todos los capítulos'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => ShowScreen(showId: v.showId!)));
              }),
      ]),
    ),
  );
}

// ---------- widgets ----------

/// Carátula 2:3 con barra de progreso; sin imagen muestra el título sobre un degradado.
class PosterCard extends ConsumerWidget {
  const PosterCard(
      {super.key,
      required this.api,
      required this.item,
      required this.onTap,
      this.onLong,
      this.width,
      this.posterFile,
      this.newBadge = false,
      this.focusNode,
      this.focusable = true});
  final Api api;
  final VideoItem item;
  final VoidCallback onTap;

  /// Nodo de foco de la carátula en TV (lo usan las filas del inicio para recordar posición).
  final FocusNode? focusNode;

  /// false para carátulas decorativas (las de las fichas, con onTap vacío): sin foco en TV.
  final bool focusable;
  final VoidCallback? onLong;
  final double? width;

  /// Carátula guardada en el dispositivo (descargas). Si se da, no se usa la red.
  final File? posterFile;

  /// Muestra la etiqueta NUEVO si se añadió en los últimos 7 días.
  final bool newBadge;

  Widget _chip(String t, Color c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration:
          BoxDecoration(color: c, borderRadius: BorderRadius.circular(5)),
      child: Text(t,
          style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              color: Colors.white)));

  Widget _placeholder() => Container(
        decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF2B2F3A), Color(0xFF14161C)])),
        padding: const EdgeInsets.all(8),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(item.isShow ? Icons.tv : Icons.movie_outlined,
              color: Colors.white38),
          const SizedBox(height: 6),
          Text(item.title,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ]),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(tvModeProvider) && focusable;
    final radius = BorderRadius.circular(10);
    final card = SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: DecoratedBox(
          // Sombra sutil para que la carátula "flote" sobre el fondo oscuro.
          decoration: BoxDecoration(borderRadius: radius, boxShadow: const [
            BoxShadow(
                color: Color(0x66000000), blurRadius: 10, offset: Offset(0, 4))
          ]),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(fit: StackFit.expand, children: [
              posterFile != null
                  ? Image.file(posterFile!,
                      fit: BoxFit.cover,
                      cacheWidth: 300,
                      errorBuilder: (_, __, ___) => _placeholder())
                  : item.posterV > 0
                      ? Image.network(api.posterUrl(item),
                          headers: api.authHeaders,
                          fit: BoxFit.cover,
                          cacheWidth: 300,
                          errorBuilder: (_, __, ___) => _placeholder())
                      : _placeholder(),
              // Velo inferior: da legibilidad a la barra de progreso.
              if (item.progress != null)
                const Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 36,
                    child: DecoratedBox(
                        decoration: BoxDecoration(
                            gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                          Color(0x00000000),
                          Color(0xAA000000)
                        ])))),
              if (item.progress != null)
                Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LinearProgressIndicator(
                        value: item.progress,
                        minHeight: 3,
                        color: _red,
                        backgroundColor: Colors.white24)),
              // Tarjeta de serie en "Continuar viendo": capítulo que toca.
              if (item.isShow && item.season != null)
                Positioned(
                    left: 7,
                    top: 7,
                    child: _chip(item.episodeLabel, const Color(0xB3000000))),
              if (newBadge &&
                  item.addedMs > 0 &&
                  DateTime.now().millisecondsSinceEpoch - item.addedMs <
                      7 * 86400000)
                Positioned(top: 7, right: 7, child: _chip('NUEVO', _red)),
              // Filete fino de luz en el borde (efecto "cristal").
              Positioned.fill(
                  child: IgnorePointer(
                      child: DecoratedBox(
                          decoration: BoxDecoration(
                              borderRadius: radius,
                              border: Border.all(
                                  color: const Color(0x1FFFFFFF),
                                  width: 0.8))))),
              // El InkWell va encima para que se vea el foco (mando de Android TV) y la ondulación.
              // En TV lo sustituye TvFocusable (aro + zoom), para no tener dos paradas de foco.
              if (!tv)
                Positioned.fill(
                    child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                            borderRadius: radius,
                            focusColor: Colors.white24,
                            onTap: onTap,
                            onLongPress: onLong))),
            ]),
          ),
        ),
      ),
    );
    // Con el mando no hay "mantener pulsado": la tecla Menú abre las opciones.
    return tv
        ? TvFocusable(
            focusNode: focusNode,
            borderRadius: 10,
            onTap: onTap,
            onLongPress: onLong,
            child: card)
        : card;
  }
}

/// Controlador de desplazamiento que recuerda su posición. Cuando la fila se descarta por estar
/// lejos y luego se vuelve a construir, arranca en la posición donde la dejaste (un controlador
/// normal vuelve a 0 y la fila se vería "saltar" al llegar a ella).
class _ShelfScroll extends ScrollController {
  _ShelfScroll([this.saved = 0]) {
    addListener(() {
      if (positions.length == 1) saved = position.pixels;
    });
  }

  double saved;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics,
          ScrollContext context, ScrollPosition? oldPosition) =>
      ScrollPositionWithSingleContext(
          physics: physics,
          context: context,
          initialPixels: saved,
          keepScrollOffset: keepScrollOffset,
          oldPosition: oldPosition,
          debugLabel: debugLabel);
}

/// Memoria de foco de una fila de carátulas del inicio (modo TV): qué carátula fue la última
/// enfocada, un nodo de foco por posición y el desplazamiento horizontal de la fila. Con esto,
/// al subir o bajar a otra fila el foco vuelve a la carátula donde lo dejaste (aunque la
/// fila la haya descartado por estar lejos: se desplaza hasta ella y se enfoca).
class ShelfFocus {
  final scroll = _ShelfScroll();

  /// Para saber si el foco está en alguna carátula de la fila.
  final rowNode = FocusNode(
      debugLabel: 'ShelfRow', canRequestFocus: false, skipTraversal: true);
  final _nodes = <int, FocusNode>{};
  int last = 0;

  bool get hasFocus => rowNode.hasFocus;

  /// Olvida la última carátula enfocada (la fila vuelve a empezar por la primera).
  void forget() => last = 0;

  FocusNode node(int i) => _nodes.putIfAbsent(i, () {
        final n = FocusNode(debugLabel: 'shelf-$i');
        n.addListener(() {
          if (n.hasPrimaryFocus) last = i;
        });
        return n;
      });

  /// Lleva el foco a la última carátula de la fila. false si no se pudo (la fila aún no está
  /// construida): entonces queda el comportamiento normal de las flechas.
  bool focusRemembered(int count) {
    if (count == 0) return false;
    final i = last.clamp(0, count - 1);
    final n = node(i);
    final before = FocusManager.instance.primaryFocus;
    if (tvUsable(n)) {
      _tvJump(n);
      _ensureIn(before);
      return true;
    }
    if (!scroll.hasClients) return false;
    final pos = scroll.position;
    const stride = ShelfRow.tvWidth + ShelfRow.tvGap;
    final target = (ShelfRow.pad +
            i * stride +
            ShelfRow.tvWidth / 2 -
            pos.viewportDimension / 2)
        .clamp(0.0, pos.maxScrollExtent)
        .toDouble();
    scroll.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (tvUsable(n)) _tvJump(n);
      _ensureIn(before);
    });
    return true;
  }

  void _ensureIn(FocusNode? before) => _tvEnsureIn(before, rowNode);

  void dispose() {
    scroll.dispose();
    rowNode.dispose();
    for (final n in _nodes.values) {
      n.dispose();
    }
  }
}

class ShelfRow extends ConsumerWidget {
  const ShelfRow(
      {super.key,
      required this.title,
      required this.items,
      required this.api,
      required this.onTap,
      required this.onLong,
      this.trailing,
      this.posterFile,
      this.focus,
      this.newBadge = false});

  /// Medidas de las carátulas en TV y relleno lateral de la fila (las usa [ShelfFocus]).
  static const double tvWidth = 170, tvGap = 16, pad = 20;

  /// Memoria de foco de la fila (solo TV, en el inicio).
  final ShelfFocus? focus;
  final String title;
  final List<VideoItem> items;
  final Api api;
  final void Function(VideoItem) onTap, onLong;
  final Widget? trailing;

  /// Carátula local de cada video (descargas); null = usar la red.
  final File? Function(VideoItem)? posterFile;
  final bool newBadge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CatalogShelf(
        title: title,
        count: items.length,
        trailing: trailing,
        focus: focus,
        card: (i, width, node) => PosterCard(
            api: api,
            item: items[i],
            width: width,
            focusNode: node,
            posterFile: posterFile?.call(items[i]),
            newBadge: newBadge,
            onTap: () => onTap(items[i]),
            onLong: () => onLong(items[i])));
  }
}

class OfflineBookShelf extends StatelessWidget {
  const OfflineBookShelf({super.key, required this.api, required this.books});
  final Api api;
  final List<AudioBook> books;
  @override
  Widget build(BuildContext context) => _CatalogShelf(
      title: 'Audiolibros descargados',
      count: books.length,
      card: (i, w, node) =>
          AudioBookCard(api: api, book: books[i], width: w, focusNode: node));
}

class _CatalogShelf extends ConsumerWidget {
  const _CatalogShelf(
      {required this.title,
      required this.count,
      required this.card,
      this.trailing,
      this.focus});
  final String title;
  final int count;
  final Widget? trailing;
  final ShelfFocus? focus;
  final Widget Function(int index, double width, FocusNode? node) card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tv = ref.watch(tvModeProvider);
    final w = tv ? ShelfRow.tvWidth : 130.0;
    final sf = tv ? focus : null;
    final col = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 12, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            // Pequeña barra roja como acento de sección.
            Container(
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                    color: _red, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 10),
            Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2))),
            if (trailing != null) trailing!,
          ])),
      SizedBox(
        // En TV deja sitio al aumento del foco (la fila no recorta).
        height: w * 1.5 + (tv ? 16 : 6),
        child: ListView.separated(
          controller: sf?.scroll,
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          padding: EdgeInsets.symmetric(
              horizontal: ShelfRow.pad, vertical: tv ? 8 : 3),
          itemCount: count,
          separatorBuilder: (_, __) =>
              SizedBox(width: tv ? ShelfRow.tvGap : 12),
          itemBuilder: (_, i) => card(i, w, sf?.node(i)),
        ),
      ),
    ]);
    return sf == null
        ? col
        : Focus(
            focusNode: sf.rowNode,
            canRequestFocus: false,
            skipTraversal: true,
            child: col);
  }
}

/// Cartel principal: fondo grande, título, datos, sinopsis y botones.
class FeaturedHero extends StatelessWidget {
  const FeaturedHero(
      {super.key,
      required this.api,
      required this.item,
      required this.onPlay,
      required this.onInfo,
      this.imageFile,
      this.playFocusNode,
      this.autofocus = false});
  final Api api;
  final VideoItem item;
  final VoidCallback onPlay, onInfo;

  /// Nodo de foco del botón Reproducir/Reanudar (lo usa la pantalla de inicio en TV para
  /// devolver el foco aquí desde la barra de arriba o desde la primera fila).
  final FocusNode? playFocusNode;

  /// En TV el botón Reproducir toma el foco al abrir.
  final bool autofocus;

  /// Fondo guardado en el dispositivo (descargas). Si se da, no se usa la red.
  final File? imageFile;

  @override
  Widget build(BuildContext context) {
    final h = math.min(MediaQuery.of(context).size.height * 0.66, 600.0);
    final img =
        item.backdropV > 0 ? api.backdropUrl(item) : api.thumbUrl(item.id);
    final meta = <String>[
      if (item.isShow && item.season != null) item.episodeLabel,
      if (item.year != null) '${item.year}',
      if (item.durationMs != null) item.durationLabel,
      if (item.genres.isNotEmpty) item.genres.take(3).join(' · '),
    ];
    final eyebrow = item.progress != null ? 'CONTINÚA VIENDO' : 'DESTACADO';
    return SizedBox(
      height: h,
      child: Stack(fit: StackFit.expand, children: [
        imageFile != null
            ? Image.file(imageFile!,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorBuilder: (_, __, ___) =>
                    const ColoredBox(color: Colors.black26))
            : Image.network(img,
                headers: api.authHeaders,
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorBuilder: (_, __, ___) =>
                    const ColoredBox(color: Colors.black26)),
        // Sombra suave a la izquierda para que el texto respire sobre cualquier imagen.
        const DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: [0.0, 0.7],
                    colors: [Color(0x66000000), Color(0x00000000)]))),
        // Oscurece arriba (barra superior).
        const DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.0, 0.25],
                    colors: [Color(0x99000000), Color(0x00000000)]))),
        // Fundido inferior muy gradual (mismo tono que el fondo en todos los pasos,
        // y va al final, encima de todo, para que no quede ninguna línea al terminar).
        const DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [
              0.30,
              0.45,
              0.58,
              0.70,
              0.82,
              0.92,
              1.0
            ],
                    colors: [
              Color(0x00141414),
              Color(0x24141414),
              Color(0x55141414),
              Color(0x8C141414),
              Color(0xC4141414),
              Color(0xF0141414),
              _bg
            ]))),
        Positioned(
          left: 20,
          right: 20,
          bottom: 28,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 18,
                  height: 2,
                  decoration: BoxDecoration(
                      color: _red, borderRadius: BorderRadius.circular(2))),
              const SizedBox(width: 8),
              Text(eyebrow,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.2,
                      color: Colors.white70)),
            ]),
            const SizedBox(height: 10),
            Text(item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 34,
                    height: 1.05,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                    shadows: [Shadow(blurRadius: 16, color: Colors.black54)])),
            const SizedBox(height: 10),
            Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (item.rating != null)
                    Text('${(item.rating! * 10).round()}% de coincidencia',
                        style: const TextStyle(
                            color: Color(0xFF46D369),
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  if (meta.isNotEmpty)
                    Text(meta.join('   ·   '),
                        style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 13,
                            letterSpacing: 0.2)),
                ]),
            if (item.overview != null && item.overview!.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Text(item.overview!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 14, height: 1.45))),
            ],
            const SizedBox(height: 20),
            Row(children: [
              Flexible(
                child: TvScrollTopOnFocus(
                    child: TvButtonFocus(
                        builder: (_, focused) => FilledButton.icon(
                            focusNode: playFocusNode,
                            autofocus: autofocus,
                            style: FilledButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: Colors.black,
                                    shape: const StadiumBorder(),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 22, vertical: 14),
                                    textStyle: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.2))
                                .copyWith(
                                    side: const WidgetStatePropertyAll(
                                        BorderSide.none)),
                            onPressed: onPlay,
                            // Con foco, el icono se tiñe del rojo de la app.
                            icon: Icon(Icons.play_arrow_rounded,
                                size: 24, color: focused ? _red : null),
                            label: Text(_heroLabel(item),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis)))),
              ),
              const SizedBox(width: 12),
              // "Más información" como botón circular: siempre cabe al lado.
              TvScrollTopOnFocus(
                  child: IconButton(
                      tooltip: 'Más información',
                      style: IconButton.styleFrom(
                              backgroundColor: Colors.white10,
                              foregroundColor: Colors.white,
                              fixedSize: const Size(50, 50))
                          .copyWith(
                              side: _focusSide(kFocusRing,
                                  const BorderSide(color: Colors.white30))),
                      onPressed: onInfo,
                      icon: const Icon(Icons.info_outline_rounded, size: 24))),
            ]),
          ]),
        ),
      ]),
    );
  }
}

String _heroLabel(VideoItem i) {
  if (i.isShow && i.season != null) {
    return '${i.progress != null ? 'Reanudar' : 'Continuar'} ${i.episodeLabel}';
  }
  return i.progress != null ? 'Reanudar' : 'Reproducir';
}

// ---------- pantalla principal del modo teatro ----------

class TheaterScreen extends ConsumerStatefulWidget {
  const TheaterScreen({super.key});
  @override
  ConsumerState<TheaterScreen> createState() => _TheaterScreenState();
}

/// Atrás en TV: el shell lo consulta antes de ir al menú lateral. Devuelve true si cerró el
/// buscador del Inicio (y por tanto Atrás ya está atendido). Solo está asignado con el buscador
/// abierto.
bool Function()? tvTheaterBack;

class _TheaterScreenState extends ConsumerState<TheaterScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  bool _searching = false, _solid = false;

  // Modo TV: la barra de arriba (buscar, campanita) y el contenido son dos zonas. Al subir a la
  // barra se recuerda de qué elemento venías y al bajar se vuelve exactamente a él.
  final _barFocus = FocusNode(
      debugLabel: 'TheaterBar', canRequestFocus: false, skipTraversal: true);
  FocusNode? _returnTo;

  // Botón Reanudar/Reproducir del cartel y primera fila de carátulas (modo TV):
  //  - ▼ desde Buscar o la campanita -> siempre al botón Reanudar.
  //  - ▲ desde la primera fila de carátulas -> al botón Reanudar.
  final _playNode = FocusNode(debugLabel: 'TheaterPlay');
  final _heroNode = FocusNode(
      debugLabel: 'TheaterHero', canRequestFocus: false, skipTraversal: true);

  // Memoria de posición de cada fila de carátulas (por título) y las filas que se pintaron,
  // en orden, para que ▲▼ lleven a la carátula recordada de la fila vecina.
  final _shelfFocus = <String, ShelfFocus>{};
  var _shelfRows = <({ShelfFocus f, int count, bool trailing})>[];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final solid = _scroll.hasClients && _scroll.offset > 60;
      if (solid != _solid) setState(() => _solid = solid);
    });
    if (ref.read(tvModeProvider)) tvHomeResetFocus = _resetFocus;
  }

  /// Foco y selección de vuelta al botón Reanudar/Reproducir del cartel, como al abrir la app
  /// desde cero: buscador cerrado, pantalla arriba y cada fila empezando por su primera
  /// carátula. Devuelve false si el botón aún no está construido (sin biblioteca).
  bool _resetFocus() {
    if (!mounted) return false;
    if (_searching) _closeSearch();
    _returnTo = null;
    for (final f in _shelfFocus.values) {
      f.forget();
    }
    if (_scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);
    void focusPlay() {
      if (mounted && tvUsable(_playNode)) _jumpTo(_playNode);
    }

    final ready = tvUsable(_playNode);
    // Un fotograma después: así el foco se pide cuando la pantalla ya está dibujada y no
    // compite con lo que se estaba quitando de en medio (intro, buscador...).
    WidgetsBinding.instance.addPostFrameCallback((_) => focusPlay());
    WidgetsBinding.instance.scheduleFrame();
    return ready;
  }

  @override
  void dispose() {
    if (tvHomeResetFocus == _resetFocus) tvHomeResetFocus = null;
    if (tvTheaterBack == _backFromSearch) tvTheaterBack = null;
    _search.dispose();
    _scroll.dispose();
    _barFocus.dispose();
    _playNode.dispose();
    _heroNode.dispose();
    for (final f in _shelfFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _jumpTo(FocusNode target) => _tvJump(target);

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || !ref.read(tvModeProvider))
      return KeyEventResult.ignored;
    final cur = FocusManager.instance.primaryFocus;
    if (cur == null) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (_barFocus.hasFocus) {
      // ▼ desde la barra: de vuelta a donde estabas (carátula, botón Reproducir...)
      // o, buscando, directo a los resultados.
      if (k == LogicalKeyboardKey.arrowDown && !tvInEditableText(cur)) {
        // Sin buscar: ▼ desde Buscar o la campanita va siempre al botón Reanudar.
        if (!_searching && tvUsable(_playNode)) {
          _jumpTo(_playNode);
          return KeyEventResult.handled;
        }
        final back = _returnTo;
        if (!_searching &&
            tvUsable(back) &&
            !back!.ancestors.contains(_barFocus)) {
          _jumpTo(back);
          return KeyEventResult.handled;
        }
        if (_searching && cur.focusInDirection(TraversalDirection.down)) {
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }
    // ▼ desde el cartel (Reanudar o Más información): a la carátula que tenías en la primera
    // fila, en vez de a la más cercana en pantalla.
    if (k == LogicalKeyboardKey.arrowDown &&
        !_searching &&
        cur is! FocusScopeNode &&
        _heroNode.hasFocus &&
        _shelfRows.isNotEmpty &&
        !_shelfRows[0].trailing) {
      return _shelfRows[0].f.focusRemembered(_shelfRows[0].count)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    // ▲▼ entre filas de carátulas: el foco va a la carátula que tenías en la fila vecina (no a
    // la más cercana en pantalla). ▲ desde la primera fila: al botón Reanudar.
    if ((k == LogicalKeyboardKey.arrowUp ||
            k == LogicalKeyboardKey.arrowDown) &&
        !_searching &&
        cur is! FocusScopeNode) {
      final i = _shelfRows.indexWhere((r) => r.f.hasFocus);
      if (i >= 0) {
        final up = k == LogicalKeyboardKey.arrowUp;
        // La fila con botón en su título ("Identificar todo") se recorre con las flechas
        // normales para poder llegar a ese botón.
        if (_shelfRows[i].trailing && up) return KeyEventResult.ignored;
        if (up && i == 0) {
          if (!tvUsable(_playNode)) return KeyEventResult.ignored;
          if (e is KeyDownEvent) _jumpTo(_playNode);
          return KeyEventResult.handled;
        }
        final j = up ? i - 1 : i + 1;
        if (j < 0 || j >= _shelfRows.length || _shelfRows[j].trailing) {
          return KeyEventResult.ignored;
        }
        return _shelfRows[j].f.focusRemembered(_shelfRows[j].count)
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
      }
    }
    // ▲ desde el contenido: si es la que lleva a la barra, el elemento actual es el de regreso.
    if (k == LogicalKeyboardKey.arrowUp &&
        e is KeyDownEvent &&
        cur is! FocusScopeNode) {
      _returnTo = cur;
    }
    return KeyEventResult.ignored;
  }

  /// Una serie abre la lista de sus capítulos; una película (o capítulo suelto), su ficha.
  void _open(VideoItem v) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => v.isShow
              ? ShowScreen(showId: v.id)
              : DetailScreen(videoId: v.id)));

  /// Lo que se ve en las filas: películas y series (los capítulos viven dentro de su serie).
  List<VideoItem> _entries(List<VideoItem> all, List<ShowItem> shows) {
    final e = [
      for (final v in all)
        if (!v.isEpisode) v,
      for (final s in shows) s.toCard(),
    ];
    return e.isEmpty ? all : e;
  }

  Future<void> _autoscrape(Api api) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final started = await api.autoscrape();
      messenger.showSnackBar(SnackBar(
          content: Text(started
              ? 'Identificando en TMDB... la biblioteca se actualizará sola.'
              : 'El servidor no tiene clave de TMDB. Añádela en la app del servidor.')));
    } catch (e) {
      messenger.showSnackBar(errorSnack(errText(e)));
    }
  }

  /// "Continuar viendo": películas a medias y UNA tarjeta por serie en curso
  /// (con el capítulo que toca). Lo último que viste, primero.
  List<VideoItem> _continueItems(List<VideoItem> all, List<ShowItem> shows) {
    return [
      for (final v in all)
        if (!v.isEpisode && v.progress != null && v.progress! < 0.95) v,
      for (final s in shows)
        if (s.inProgress) s.toContinueCard(),
    ]..sort((a, b) => b.watchedMs.compareTo(a.watchedMs));
  }

  /// En "Continuar viendo" tocar reanuda directamente (como Netflix).
  Future<void> _resume(Api api, VideoItem v) =>
      v.isShow ? _playNext(context, api, v.id) : playVideo(context, api, v);

  /// Destacado: lo último que estabas viendo; si no hay, uno estable durante el día.
  VideoItem _featured(List<VideoItem> entries, List<VideoItem> cont) {
    for (final c in cont) {
      if (c.backdropV > 0) return c;
    }
    final withArt = entries.where((v) => v.backdropV > 0).toList();
    final pool = withArt.isNotEmpty ? withArt : entries;
    return pool[
        (DateTime.now().millisecondsSinceEpoch ~/ 86400000) % pool.length];
  }

  List<Widget> _shelves(Api api, List<VideoItem> entries, List<VideoItem> cont,
      List<AudioBook> books) {
    final rows = <Widget>[];
    final order = <({ShelfFocus f, int count, bool trailing})>[];
    void add(String title, List<VideoItem> list,
        {Widget? trailing,
        void Function(VideoItem)? onTap,
        bool newBadge = false}) {
      if (list.isEmpty) return;
      final sf = _shelfFocus.putIfAbsent(title, ShelfFocus.new);
      order.add((f: sf, count: list.length, trailing: trailing != null));
      rows.add(ShelfRow(
          title: title,
          items: list,
          api: api,
          focus: sf,
          trailing: trailing,
          newBadge: newBadge,
          onTap: onTap ?? _open,
          onLong: (v) => _options(context, ref, api, v)));
    }

    add('Continuar viendo', cont, onTap: (v) => _resume(api, v));

    final recent = [...entries]..sort((a, b) => b.addedMs.compareTo(a.addedMs));
    add('Agregados recientemente', recent.take(20).toList(), newBadge: true);

    if (books.isNotEmpty) {
      final sf = _shelfFocus.putIfAbsent('lumen:audiobooks', ShelfFocus.new);
      order.add((f: sf, count: books.length, trailing: false));
      rows.add(_CatalogShelf(
          title: 'Audiolibros',
          count: books.length,
          focus: sf,
          card: (i, w, node) => AudioBookCard(
              api: api, book: books[i], width: w, focusNode: node)));
    }
    final series = entries.where((v) => v.isShow).toList();
    if (series.isNotEmpty) {
      add('Series', series);
      add('Películas', entries.where((v) => !v.isShow).toList());
    }

    final byGenre = <String, List<VideoItem>>{};
    for (final v in entries) {
      for (final g in v.genres) {
        (byGenre[g] ??= []).add(v);
      }
    }
    final genres = byGenre.entries.where((e) => e.value.length >= 2).toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    for (final e in genres.take(8)) {
      add(e.key, e.value);
    }

    add('Sin identificar',
        entries.where((v) => !v.matched && v.posterV == 0).toList(),
        trailing: TextButton(
            onPressed: () => _autoscrape(api),
            child: const Text('Identificar todo')));
    add('Toda la biblioteca', entries);
    _shelfRows = order;
    return rows;
  }

  Widget _results(
      Api api, List<VideoItem> all, List<AudioBook> books, double top) {
    final q = _search.text.trim().toLowerCase();
    final items = all
        .where((v) =>
            v.title.toLowerCase().contains(q) ||
            '${v.year ?? ''}'.contains(q) ||
            v.genres.any((g) => g.toLowerCase().contains(q)))
        .toList();
    final matchedBooks = books
        .where((b) => [b.title, b.author, b.narrator, 'audiolibro']
            .any((s) => s.toLowerCase().contains(q)))
        .toList();
    if (items.isEmpty && matchedBooks.isEmpty)
      return const Center(child: Text('Sin resultados'));
    final tv = ref.watch(tvModeProvider);
    return GridView.builder(
      cacheExtent: tv ? 1200 : null,
      // TV: la barra es más alta y las carátulas crecen al enfocarse (no se recortan).
      clipBehavior: tv ? Clip.none : Clip.hardEdge,
      padding: EdgeInsets.fromLTRB(
          tv ? 20 : 12, top + (tv ? 88 : 64), tv ? 20 : 12, 20),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: ref.watch(tvModeProvider) ? 190 : 150,
          childAspectRatio: 2 / 3,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8),
      itemCount: items.length + matchedBooks.length,
      itemBuilder: (_, i) => i >= items.length
          ? AudioBookCard(api: api, book: matchedBooks[i - items.length])
          : PosterCard(
              api: api,
              item: items[i],
              onTap: () => _open(items[i]),
              onLong: () => _options(context, ref, api, items[i])),
    );
  }

  void _openSearch() {
    tvTheaterBack = _backFromSearch;
    setState(() {
      _returnTo = null;
      _searching = true;
    });
  }

  void _closeSearch() {
    if (tvTheaterBack == _backFromSearch) tvTheaterBack = null;
    setState(() {
      _returnTo = null;
      _searching = false;
      _search.clear();
    });
  }

  /// Atrás con el buscador abierto (llega desde el shell, ver [tvTheaterBack]): lo cierra. Si el
  /// foco estaba en esta pestaña (resultados, campo, cerrar) pasa al botón Reanudar, porque los
  /// resultados desaparecen y con ellos el foco; si estaba en el menú lateral, se queda allí.
  bool _backFromSearch() {
    if (!mounted || !_searching) return false;
    final inside = FocusScope.of(context).hasFocus;
    _closeSearch();
    if (inside) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && tvUsable(_playNode)) _jumpTo(_playNode);
      });
      WidgetsBinding.instance.scheduleFrame();
    }
    return true;
  }

  /// Barra de TV. Buscar es un botón con nombre ("🔍 Buscar", en TV un icono suelto no dice
  /// nada) y, al abrirlo, un campo en forma de píldora con su propio botón de cerrar. Todo mide
  /// 46 px de alto, así que cada aro de foco (radio 23) coincide con su forma.
  Widget _tvBar(double top) {
    final solid = _solid || _searching;
    const fill = Color(0x14FFFFFF);
    return Container(
      height: top + 76,
      padding: EdgeInsets.only(top: top, left: 20, right: 20),
      decoration: BoxDecoration(
          color: solid ? _bg.withOpacity(0.96) : null,
          border: solid
              ? const Border(
                  bottom: BorderSide(color: Color(0x14FFFFFF), width: 0.5))
              : null,
          gradient: solid
              ? null
              : const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xCC000000), Color(0x00000000)])),
      child: Row(children: [
        if (_searching) ...[
          Expanded(
            child: SizedBox(
              height: 46,
              child: TvTextEntry(
                startEditing: true,
                borderRadius: 23,
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.center,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 16),
                  decoration: InputDecoration(
                    hintText: 'Títulos, géneros, años...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: fill,
                    prefixIcon: const Icon(Icons.search_rounded,
                        size: 22, color: Colors.white54),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(23),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
              tooltip: 'Cerrar búsqueda',
              style: IconButton.styleFrom(
                  backgroundColor: fill, fixedSize: const Size(46, 46)),
              icon: const Icon(Icons.close_rounded),
              onPressed: _closeSearch),
        ] else ...[
          const Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: 'LUMEN',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 6)),
                    TextSpan(
                        text: '.',
                        style: TextStyle(
                            color: _red,
                            fontSize: 22,
                            fontWeight: FontWeight.w900)),
                  ]),
                  maxLines: 1),
            ),
          ),
          _TvSearchButton(onTap: _openSearch),
          const SizedBox(width: 10),
          const NewsBell(),
        ],
      ]),
    );
  }

  Widget _bar(Api api, double top) {
    if (ref.watch(tvModeProvider)) return _tvBar(top);
    final solid = _solid || _searching;
    return Container(
      height: top + 60,
      padding: EdgeInsets.only(top: top, left: 20, right: 6),
      decoration: BoxDecoration(
          color: solid ? _bg.withOpacity(0.96) : null,
          border: solid
              ? const Border(
                  bottom: BorderSide(color: Color(0x14FFFFFF), width: 0.5))
              : null,
          gradient: solid
              ? null
              : const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xCC000000), Color(0x00000000)])),
      child: Row(children: [
        if (_searching)
          Expanded(
              child: TvTextEntry(
                  startEditing: true,
                  child: TextField(
                      controller: _search,
                      autofocus: true,
                      style: const TextStyle(fontSize: 16),
                      decoration: const InputDecoration(
                          hintText: 'Títulos, géneros, años...',
                          hintStyle: TextStyle(color: Colors.white38),
                          border: InputBorder.none),
                      onChanged: (_) => setState(() {}))))
        else ...[
          const Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              // Marca discreta: letras espaciadas y un punto rojo como único acento.
              child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: 'LUMEN',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 6)),
                    TextSpan(
                        text: '.',
                        style: TextStyle(
                            color: _red,
                            fontSize: 22,
                            fontWeight: FontWeight.w900)),
                  ]),
                  maxLines: 1),
            ),
          ),
        ],
        IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: 'Buscar',
            onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _search.clear();
                })),
        if (!_searching) ...[
          const NewsBell(),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    if (api == null) return const SizedBox();
    final lib = ref.watch(libraryProvider);
    final bookState = ref.watch(audioBooksProvider);
    final books = bookState.valueOrNull ?? const <AudioBook>[];
    final all = lib.valueOrNull; // conserva la lista mientras se refresca
    final shows = ref.watch(showsProvider).valueOrNull ?? const <ShowItem>[];
    final entries = all == null ? const <VideoItem>[] : _entries(all, shows);
    final top = MediaQuery.of(context).padding.top;

    Widget content;
    if (all == null) {
      content = lib.hasError
          ? Center(child: Text('Error: ${lib.error}'))
          : const Center(child: CircularProgressIndicator(color: _red));
    } else if (all.isEmpty && books.isEmpty) {
      _shelfRows = [];
      content = bookState.isLoading
          ? const Center(child: CircularProgressIndicator())
          : bookState.hasError
              ? Center(
                  child: TextButton(
                      onPressed: () => ref.invalidate(audioBooksProvider),
                      child: const Text('Reintentar cargar audiolibros')))
              : const Center(child: Text('Biblioteca vacía'));
    } else if (_searching && _search.text.trim().isNotEmpty) {
      content = _results(api, entries, books, top);
    } else {
      final cont = _continueItems(all, shows);
      final hero = entries.isEmpty ? null : _featured(entries, cont);
      final shelves = _shelves(api, entries, cont, books);
      content = RefreshIndicator(
        edgeOffset: top + 56,
        onRefresh: () async {
          await ref.refresh(libraryProvider.future);
        },
        child: ListView(
            controller: _scroll,
            padding: EdgeInsets.zero,
            // En TV se construyen más filas por delante y por detrás: con el mando, ▼/▲
            // solo saltan a elementos que ya existen.
            cacheExtent: ref.watch(tvModeProvider) ? 2000 : null,
            children: [
              // El nodo del cartel sirve para saber si el foco está en Reanudar o en Más info.
              if (hero == null)
                SizedBox(height: top + 72)
              else
                Focus(
                    focusNode: _heroNode,
                    canRequestFocus: false,
                    skipTraversal: true,
                    child: FeaturedHero(
                        api: api,
                        item: hero,
                        playFocusNode: _playNode,
                        autofocus: ref.watch(tvModeProvider),
                        onPlay: () => hero.isShow
                            ? _playNext(context, api, hero.id)
                            : playVideo(context, api, hero),
                        onInfo: () => _open(hero))),
              ...shelves,
              if (bookState.hasError)
                TextButton(
                    onPressed: () => ref.invalidate(audioBooksProvider),
                    child: const Text('Reintentar cargar audiolibros')),
              const SizedBox(height: 32),
            ]),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      body: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Stack(children: [
          Positioned.fill(child: content),
          Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Focus(
                  focusNode: _barFocus,
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: _bar(api, top))),
        ]),
      ),
    );
  }
}

/// Botón "Buscar" de la barra de TV: píldora de 46 px con icono y nombre, con fondo oscuro
/// translúcido para que se lea sobre cualquier portada. El aro de foco (radio 23 = 46 / 2) es la
/// misma forma que la píldora.
class _TvSearchButton extends StatelessWidget {
  const _TvSearchButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TvFocusable(
        borderRadius: 23,
        scale: 1,
        nearestScrollOnly: true,
        onTap: onTap,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
              color: const Color(0x59000000),
              borderRadius: BorderRadius.circular(23)),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.search_rounded, size: 22),
            SizedBox(width: 8),
            Text('Buscar',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

// ---------- piezas compartidas de las fichas (película / serie) ----------

const _gold = Color(0xFFF5C518);

/// Oscurece la parte de arriba de la imagen (para que se lea la flecha de volver).
const Widget _topVignette = DecoratedBox(
    decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0.0, 0.28],
            colors: [Color(0x99000000), Color(0x00000000)])));

/// Fundido inferior muy gradual hasta el color de fondo (sin línea al terminar).
const Widget _bottomFade = DecoratedBox(
    decoration: BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [
      0.30,
      0.45,
      0.58,
      0.70,
      0.82,
      0.92,
      1.0
    ],
            colors: [
      Color(0x00141414),
      Color(0x24141414),
      Color(0x55141414),
      Color(0x8C141414),
      Color(0xC4141414),
      Color(0xF0141414),
      _bg
    ])));

/// Cabecera de una ficha: imagen grande, fundido y, abajo, etiqueta + título.
class _DetailHeader extends ConsumerWidget {
  const _DetailHeader(
      {required this.api,
      required this.url,
      required this.title,
      this.eyebrow});
  final Api api;
  final String url, title;
  final String? eyebrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.of(context).size;
    double h = (size.width * 0.74).clamp(290.0, 450.0);
    // En TV (pantalla apaisada) la cabecera es más baja: así el botón Reproducir queda a la vista.
    final tv = ref.watch(tvModeProvider);
    if (tv) h = math.min(h, size.height * 0.42);
    return SizedBox(
      height: h,
      child: Stack(fit: StackFit.expand, children: [
        Image.network(url,
            headers: api.authHeaders,
            fit: BoxFit.cover,
            // En TV la cabecera es baja y apaisada: se baja el encuadre para que se vea
            // más la parte de abajo de la portada (como en Continuar viendo del inicio).
            alignment: tv ? const Alignment(0, 0.3) : Alignment.topCenter,
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: Colors.black26)),
        _topVignette,
        _bottomFade,
        Positioned(
          left: 20,
          right: 20,
          bottom: 10,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (eyebrow != null) ...[
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(
                    width: 18,
                    height: 2,
                    decoration: BoxDecoration(
                        color: _red, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(eyebrow!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.0,
                          color: Colors.white70)),
                ),
              ]),
              const SizedBox(height: 10),
            ],
            Text(title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 34,
                    height: 1.05,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.6,
                    shadows: [Shadow(blurRadius: 16, color: Colors.black54)])),
          ]),
        ),
      ]),
    );
  }
}

/// Flecha de volver sobre un círculo translúcido (se ve sobre cualquier imagen).
class _GlassBack extends StatelessWidget {
  const _GlassBack();
  @override
  Widget build(BuildContext context) => Center(
        child: SizedBox(
          width: 40,
          height: 40,
          child: Material(
            color: const Color(0x66000000),
            shape: const CircleBorder(),
            child: IconButton(
                padding: EdgeInsets.zero,
                tooltip: 'Atrás',
                icon: const Icon(Icons.arrow_back_rounded, size: 22),
                onPressed: () => Navigator.maybePop(context)),
          ),
        ),
      );
}

/// Sinopsis plegable: si es larga se corta y aparece solo una flechita sutil (v / ^).
class _Overview extends StatefulWidget {
  const _Overview(this.text);
  final String text;
  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  static const _lines = 6;
  static const _style =
      TextStyle(fontSize: 15, height: 1.55, color: Colors.white70);
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, c) {
      final tp = TextPainter(
          text: TextSpan(text: widget.text, style: _style),
          maxLines: _lines,
          textScaler: scaler,
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: c.maxWidth);
      final long = tp.didExceedMaxLines;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Sin AnimatedSize: al cambiar maxLines dejaba el texto expandido en una sola línea.
        Text(widget.text,
            maxLines: (_open || !long) ? null : _lines,
            overflow:
                (_open || !long) ? TextOverflow.visible : TextOverflow.ellipsis,
            style: _style),
        if (long)
          InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: Icon(
                      _open
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 28,
                      color: Colors.white38))),
      ]);
    });
  }
}

// ---------- piezas de la ficha de película en TV ----------

/// Elemento enfocable con el mando que NO desplaza la pantalla al recibir el foco (a diferencia
/// de TvFocusable, que centra el elemento): la cabecera de la ficha ocupa toda la pantalla y no
/// debe moverse. Aro fino + velo claro, con el radio de su forma.
class _TvTextFocus extends StatefulWidget {
  const _TvTextFocus(
      {required this.builder, required this.onTap, this.radius = 12});
  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback onTap;
  final double radius;
  @override
  State<_TvTextFocus> createState() => _TvTextFocusState();
}

class _TvTextFocusState extends State<_TvTextFocus> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.radius);
    return FocusableActionDetector(
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: kFocusDuration,
          curve: kFocusCurve,
          decoration: BoxDecoration(
              borderRadius: r,
              color: _focused ? const Color(0x14FFFFFF) : Colors.transparent),
          foregroundDecoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(
                  color: _focused ? kFocusRing : Colors.transparent,
                  width: kFocusWidth)),
          child: widget.builder(context, _focused),
        ),
      ),
    );
  }
}

/// Sinopsis para TV: letra grande, [lines] líneas como máximo. Si no cabe entera se puede
/// enfocar y, con OK, se abre el texto completo (las flechas ▲▼ lo desplazan).
class _TvOverview extends StatelessWidget {
  const _TvOverview(
      {required this.title, required this.text, this.lines = 4, this.onDown});
  final String title, text;
  final int lines;

  /// ▼ desde la sinopsis (p. ej. para ir al botón Reanudar). Devuelve true si movió el foco.
  final bool Function()? onDown;

  static const _style =
      TextStyle(fontSize: 17, height: 1.5, color: Colors.white70);

  void _open(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => _TvTextDialog(title: title, text: text));

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, c) {
      // Mide con el ancho útil (el bloque enfocable lleva 12 px de margen a cada lado).
      final tp = TextPainter(
          text: TextSpan(text: text, style: _style),
          maxLines: lines,
          textScaler: scaler,
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: math.max(c.maxWidth - 24, 100));
      final body = Text(text,
          maxLines: lines, overflow: TextOverflow.ellipsis, style: _style);
      if (!tp.didExceedMaxLines) return body;
      // Se corre 12 px a la izquierda (solo al pintar) para que el texto siga alineado con el
      // título y la línea de datos; el aro de foco queda un poco por fuera, como en tvOS.
      return _TvKeyTo(
        keyId: LogicalKeyboardKey.arrowDown,
        enabled: onDown != null,
        onKey: () => onDown?.call() ?? false,
        child: Transform.translate(
          offset: const Offset(-12, 0),
          child: _TvTextFocus(
            onTap: () => _open(context),
            builder: (_, __) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    body,
                    const Icon(Icons.keyboard_arrow_down_rounded,
                        size: 26, color: Colors.white38),
                  ]),
            ),
          ),
        ),
      );
    });
  }
}

/// Sinopsis completa en un diálogo: ▲▼ desplazan el texto, OK o Atrás lo cierran.
class _TvTextDialog extends StatefulWidget {
  const _TvTextDialog({required this.title, required this.text});
  final String title, text;
  @override
  State<_TvTextDialog> createState() => _TvTextDialogState();
}

class _TvTextDialogState extends State<_TvTextDialog> {
  final _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      if (_ctrl.hasClients) {
        final to =
            (_ctrl.offset + (k == LogicalKeyboardKey.arrowDown ? 90 : -90))
                .clamp(0.0, _ctrl.position.maxScrollExtent)
                .toDouble();
        _ctrl.animateTo(to,
            duration: const Duration(milliseconds: 120), curve: Curves.easeOut);
      }
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter ||
            k == LogicalKeyboardKey.gameButtonA)) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // Atrás lo cierra como siempre
  }

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: const Color(0xFF1B1B1B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 96, vertical: 40),
        child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(36, 30, 36, 22),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      controller: _ctrl,
                      child: Text(widget.text,
                          style: const TextStyle(
                              fontSize: 19,
                              height: 1.55,
                              color: Colors.white70)),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text('OK o Atrás para cerrar',
                      style: TextStyle(fontSize: 13, color: Colors.white38)),
                ]),
          ),
        ),
      );
}

/// Botón secundario de la ficha en TV: círculo con solo el icono y, al enfocarlo, se ensancha
/// y muestra su nombre (el mando no tiene "mantener pulsado" ni tooltips, y dos iconos sueltos
/// no se sabe qué hacen).
class _TvActionButton extends StatelessWidget {
  const _TvActionButton(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TvScrollTopOnFocus(
        child: TvButtonFocus(
          // AnimatedSize recorta el botón (ya a su tamaño final) con un rectángulo mientras
          // crece, y en la transición se veían las esquinas cuadradas. El ClipRRect de fuera
          // (mismo radio que la píldora, 30 = mitad del alto) redondea ese recorte en cada fotograma.
          builder: (_, focused) => ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: AnimatedSize(
              duration: kFocusDuration,
              curve: kFocusCurve,
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                        backgroundColor: Colors.white12,
                        foregroundColor: Colors.white,
                        shape: const StadiumBorder(),
                        minimumSize: const Size(60, 60),
                        padding:
                            EdgeInsets.symmetric(horizontal: focused ? 24 : 0),
                        textStyle: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600))
                    .copyWith(
                        side: const WidgetStatePropertyAll(BorderSide.none)),
                onPressed: onTap,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 28),
                  if (focused) ...[
                    const SizedBox(width: 10),
                    Text(label, maxLines: 1),
                  ],
                ]),
              ),
            ),
          ),
        ),
      );
}

/// Año · duración · ★ nota ... en una sola línea discreta (la nota va en dorado).
Widget _metaLine(List<String> meta, {Widget? lead, double size = 13.5}) {
  final spans = <InlineSpan>[];
  // Sello de clasificación de edades al inicio de la línea.
  if (lead != null) {
    spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child:
            Padding(padding: const EdgeInsets.only(right: 12), child: lead)));
  }
  for (var i = 0; i < meta.length; i++) {
    if (i > 0) {
      spans.add(const TextSpan(
          text: '   ·   ', style: TextStyle(color: Colors.white24)));
    }
    final m = meta[i];
    spans.add(TextSpan(
        text: m,
        style: m.startsWith('★')
            ? const TextStyle(color: _gold, fontWeight: FontWeight.w700)
            : null));
  }
  return Text.rich(TextSpan(
      style:
          TextStyle(color: Colors.white60, fontSize: size, letterSpacing: 0.2),
      children: spans));
}

/// Título de sección con la barrita roja (igual que en las filas del inicio).
Widget _sectionTitle(String t) => Row(children: [
      Container(
          width: 3,
          height: 16,
          decoration: BoxDecoration(
              color: _red, borderRadius: BorderRadius.circular(2))),
      const SizedBox(width: 10),
      Text(t,
          style: const TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
    ]);

/// Etiquetas de género como píldoras con borde fino.
Widget _genrePills(List<String> genres, {double size = 12.5}) =>
    Wrap(spacing: 8, runSpacing: 8, children: [
      for (final g in genres)
        Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white24, width: 0.8)),
            child: Text(g,
                style: TextStyle(
                    fontSize: size,
                    color: Colors.white70,
                    letterSpacing: 0.3))),
    ]);

/// "DIRECCIÓN" en pequeño y, debajo, los nombres.
Widget _credit(String label, String value, {bool big = false}) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label.toUpperCase(),
          style: TextStyle(
              fontSize: big ? 12.5 : 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.6,
              color: Colors.white38)),
      const SizedBox(height: 4),
      Text(value,
          style: TextStyle(
              fontSize: big ? 16 : 14, height: 1.45, color: Colors.white70)),
    ]));

Widget _playButton(String label, VoidCallback onPressed,
        {bool autofocus = false, bool large = false, FocusNode? focusNode}) =>
    TvScrollTopOnFocus(
        child: TvButtonFocus(
            builder: (_, focused) => FilledButton.icon(
                autofocus: autofocus,
                focusNode: focusNode,
                style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        shape: const StadiumBorder(),
                        padding: EdgeInsets.symmetric(
                            horizontal: large ? 34 : 24,
                            vertical: large ? 18 : 14),
                        textStyle: TextStyle(
                            fontSize: large ? 17 : null,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2))
                    .copyWith(
                        side: const WidgetStatePropertyAll(BorderSide.none)),
                onPressed: onPressed,
                icon: Icon(Icons.play_arrow_rounded, size: large ? 30 : 24, color: focused ? _red : null),
                label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis))));

Widget _roundIcon(IconData icon, String tip, VoidCallback onTap) =>
    TvScrollTopOnFocus(
        child: IconButton(
            tooltip: tip,
            style: IconButton.styleFrom(
                    backgroundColor: Colors.white10,
                    foregroundColor: Colors.white,
                    fixedSize: const Size(50, 50))
                .copyWith(
                    side: _focusSide(
                        kFocusRing, const BorderSide(color: Colors.white30))),
            onPressed: onTap,
            icon: Icon(icon, size: 24)));

/// Los botones secundarios (Descargar, Todos los capítulos...) se ven como píldoras
/// translúcidas, sin tocar los widgets de descargas.
Widget _ghostTheme(BuildContext context, Widget child) => Theme(
    data: Theme.of(context).copyWith(
        outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.white10,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 12),
                    textStyle: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13.5))
                .copyWith(
                    side: _focusSide(
                        kFocusRing, const BorderSide(color: Colors.white30))))),
    child: child);

Widget _seasonChip(String label, bool sel, VoidCallback onTap,
        {bool tv = false}) =>
    Padding(
        padding: const EdgeInsets.only(right: 8),
        child: _chipFocus(
            tv,
            ChoiceChip(
                label: Text(label),
                selected: sel,
                showCheckmark: false,
                onSelected: (_) => onTap(),
                shape: const StadiumBorder(),
                side: BorderSide(color: sel ? Colors.white : Colors.white24),
                backgroundColor: Colors.transparent,
                selectedColor: Colors.white,
                labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: sel ? Colors.black : Colors.white70))));

/// En TV el chip seleccionado es blanco y un velo claro no se vería: lleva el aro de foco
/// fino de los botones.
Widget _chipFocus(bool tv, Widget chip) => tv
    ? TvButtonFocus(radius: 999, gap: 3, scale: 1.05, builder: (_, __) => chip)
    : chip;

// ---------- capítulos / video en filas horizontales (TV) ----------

class _CardOptionsIntent extends Intent {
  const _CardOptionsIntent();
}

/// Tarjeta horizontal de un capítulo (o del video de una película) para TV: imagen 16:9 con
/// progreso, título, duración y sinopsis. OK reproduce; la tecla Menú (≡) abre las opciones.
/// Al enfocarla se centra en su fila y la fila en la pantalla.
class _TvEpisodeCard extends StatefulWidget {
  const _TvEpisodeCard(
      {super.key,
      required this.api,
      required this.v,
      required this.onTap,
      required this.onLong,
      this.focusNode,
      this.onFocused,
      this.isNew = false,
      this.movie = false});
  final Api api;
  final VideoItem v;
  final VoidCallback onTap, onLong;
  final FocusNode? focusNode;

  /// Se avisa cuando la tarjeta recibe el foco (la ficha recuerda cuál fue el último).
  final VoidCallback? onFocused;
  final bool isNew, movie;

  /// Tamaño exterior de la tarjeta (con su relleno) y separación: la fila los usa para calcular
  /// a qué punto desplazarse.
  static const double width = 312, height = 296, gap = 10;

  @override
  State<_TvEpisodeCard> createState() => _TvEpisodeCardState();
}

class _TvEpisodeCardState extends State<_TvEpisodeCard> {
  bool _focused = false;

  /// Al recibir el foco la tarjeta se centra en su fila (horizontal) y la fila en la pantalla
  /// (vertical). Se usa Scrollable.ensureVisible, que recorre cada desplazable de fuera hacia
  /// dentro con la geometría correcta; llamar a ensureVisible de cada posición por separado
  /// medía el eje vertical con el visor horizontal y la pantalla no bajaba a la fila.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(context,
          alignment: 0.5,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.v, api = widget.api;
    final done = v.progress != null && v.progress! >= 0.95;
    final meta = [
      if (v.durationMs != null) v.durationLabel,
      if (done) 'Visto',
    ].join(' · ');
    final file = [
      if (v.height != null) '${v.height}p',
      if (v.vcodec != null) v.vcodec!,
      v.sizeLabel,
    ].where((e) => e.isNotEmpty).join(' · ');
    final title = widget.movie || v.episode == null
        ? v.title
        : '${v.episode}. ${v.epTitle ?? v.title}';
    final overview = widget.movie ? null : v.overview;
    final r = BorderRadius.circular(14);

    return FocusableActionDetector(
      focusNode: widget.focusNode,
      onShowFocusHighlight: (f) => setState(() => _focused = f),
      onFocusChange: (has) {
        if (has) {
          widget.onFocused?.call();
          _reveal();
        }
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.contextMenu): _CardOptionsIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        }),
        _CardOptionsIntent: CallbackAction<_CardOptionsIntent>(onInvoke: (_) {
          widget.onLong();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLong,
        child: AnimatedScale(
          scale: _focused ? 1.04 : 1,
          duration: kFocusDuration,
          curve: kFocusCurve,
          child: AnimatedContainer(
            duration: kFocusDuration,
            curve: kFocusCurve,
            width: _TvEpisodeCard.width,
            height: _TvEpisodeCard.height,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                borderRadius: r,
                color: _focused ? const Color(0x14FFFFFF) : Colors.transparent),
            foregroundDecoration: BoxDecoration(
                borderRadius: r,
                border: Border.all(
                    color: _focused ? kFocusRing : Colors.transparent,
                    width: kFocusWidth)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(fit: StackFit.expand, children: [
                    Image.network(
                        v.stillV > 0 ? api.stillUrl(v) : api.thumbUrl(v.id),
                        headers: api.authHeaders,
                        fit: BoxFit.cover,
                        cacheWidth: 600,
                        errorBuilder: (_, __, ___) => const ColoredBox(
                            color: Colors.black26,
                            child: Icon(Icons.play_circle_outline,
                                size: 40, color: Colors.white38))),
                    if (v.progress != null && !done)
                      Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                              value: v.progress,
                              minHeight: 4,
                              color: _red,
                              backgroundColor: Colors.black54)),
                    if (done)
                      const Positioned(
                          top: 8,
                          right: 8,
                          child: Icon(Icons.check_circle,
                              size: 22, color: Color(0xFF46D369))),
                    if (widget.isNew && !done)
                      Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                  color: _red,
                                  borderRadius: BorderRadius.circular(4)),
                              child: const Text('NUEVO',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white)))),
                  ]),
                ),
              ),
              const SizedBox(height: 10),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w600)),
              if (meta.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(meta,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12.5))),
              if (widget.movie && file.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(file,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12.5))),
              if (overview != null && overview.isNotEmpty)
                Flexible(
                    child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(overview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                                height: 1.3)))),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Fila horizontal de tarjetas. Si se da [initialIndex] se abre ya centrada en esa tarjeta
/// (el capítulo que toca ver). Con [controller] la ficha puede desplazar la fila a una tarjeta
/// que aún no está construida (las filas son perezosas) antes de enfocarla.
class _TvEpisodeRow extends StatefulWidget {
  const _TvEpisodeRow(
      {super.key,
      required this.count,
      required this.itemBuilder,
      this.initialIndex = 0,
      this.controller});
  final int count, initialIndex;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final ScrollController? controller;

  /// Relleno de la fila: 56 de margen menos los 6 de relleno de la tarjeta.
  static const double pad = 50;

  /// Desplazamiento que deja centrada en la pantalla la tarjeta [index].
  static double offsetFor(int index) {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final screenW = view.physicalSize.width / view.devicePixelRatio;
    const stride = _TvEpisodeCard.width + _TvEpisodeCard.gap;
    return math.max(
        0, pad + index * stride + _TvEpisodeCard.width / 2 - screenW / 2);
  }

  @override
  State<_TvEpisodeRow> createState() => _TvEpisodeRowState();
}

class _TvEpisodeRowState extends State<_TvEpisodeRow> {
  late final ScrollController _ctrl = widget.controller ??
      ScrollController(
          initialScrollOffset: _TvEpisodeRow.offsetFor(widget.initialIndex));

  @override
  void dispose() {
    if (widget.controller == null) _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        // Alto de la tarjeta + holgura arriba y abajo para el aumento al enfocar.
        height: _TvEpisodeCard.height + 28,
        child: ListView.builder(
          controller: _ctrl,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
              horizontal: _TvEpisodeRow.pad, vertical: 14),
          itemCount: widget.count,
          itemBuilder: (ctx, i) => Padding(
              padding: EdgeInsets.only(
                  right: i == widget.count - 1 ? 0 : _TvEpisodeCard.gap),
              child: widget.itemBuilder(ctx, i)),
        ),
      );
}

/// ▼ dirigido: al pulsar abajo en [child] se llama a [onDown]; si devuelve true el foco ya se
/// movió (p. ej. al último capítulo que tenías o al que toca ver) y no se hace nada más; si
/// devuelve false, queda el comportamiento normal de las flechas.
class _TvDownTo extends StatelessWidget {
  const _TvDownTo(
      {required this.onDown, required this.child, this.enabled = true});
  final bool Function() onDown;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => enabled
      ? Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, e) {
            if (e is! KeyDownEvent ||
                e.logicalKey != LogicalKeyboardKey.arrowDown) {
              return KeyEventResult.ignored;
            }
            return onDown() ? KeyEventResult.handled : KeyEventResult.ignored;
          },
          child: child)
      : child;
}

// ---------- piezas comunes de las fichas en TV (película y serie) ----------

/// "Quedan 1h 52m" / "Vista" según el progreso; null si no se empezó.
String? _remainingLabel(VideoItem v) {
  final d = v.durationMs, p = v.progress;
  if (d == null || p == null) return null;
  if (p >= 0.95) return 'Vista';
  final m =
      math.max(1, Duration(milliseconds: (d * (1 - p)).round()).inMinutes);
  return 'Quedan ${m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m'}';
}

/// Cartel de la ficha en TV: MISMO tratamiento de imagen que el cartel del inicio
/// (FeaturedHero): portada apaisada a todo el ancho, alineada arriba, con una sombra suave a la
/// izquierda, otra arriba y el fundido inferior larguísimo hasta el color de fondo. La
/// información (título, datos, sinopsis, botones) va encima, abajo a la izquierda.
/// Si el bloque de texto no cabe en una pantalla muy baja, se reduce solo (FittedBox).
Widget _tvHero(Api api, String url, Size size, Widget info) => SizedBox(
      // Deja asomar un poco de lo de abajo: avisa de que se puede bajar con ▼.
      height: math.max(size.height - 64, 420.0),
      child: Stack(fit: StackFit.expand, children: [
        Image.network(url,
            headers: api.authHeaders,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: Colors.black26)),
        // Sombra suave a la izquierda (igual que en el inicio).
        const DecoratedBox(
            decoration: BoxDecoration(
                gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    stops: [0.0, 0.7],
                    colors: [Color(0x66000000), Color(0x00000000)]))),
        _topVignette,
        _bottomFade,
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 28, 56, 36),
          child: LayoutBuilder(builder: (context, c) {
            final w = math.min(c.maxWidth, 660.0);
            return Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(
                width: w,
                height: c.maxHeight,
                child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.bottomLeft,
                    child: SizedBox(width: w, child: info)),
              ),
            );
          }),
        ),
      ]),
    );

/// Bloque de información del cartel en TV: etiqueta, título, datos, lema, sinopsis, géneros,
/// botones ([actions]) y, si se empezó, la barra de progreso con el tiempo que queda.
Widget _tvInfo({
  required String eyebrow,
  required String title,
  required List<String> meta,
  required Widget actions,
  required bool compact,
  Widget? age,
  String? tagline,
  Widget? overview,
  List<String> genres = const [],
  double? progress,
  String? progressLabel,
}) =>
    Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 28,
                height: 3,
                decoration: BoxDecoration(
                    color: _red, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 10),
            Text(eyebrow,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.4,
                    color: Colors.white70)),
          ]),
          const SizedBox(height: 12),
          Text(title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: compact ? 34 : 42,
                  height: 1.05,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                  shadows: const [
                    Shadow(blurRadius: 18, color: Colors.black54)
                  ])),
          if (meta.isNotEmpty || age != null) ...[
            const SizedBox(height: 14),
            // La insignia de edades abre un panel: en TV no debe ser una parada de foco.
            _metaLine(meta,
                lead: age == null ? null : ExcludeFocus(child: age), size: 16),
          ],
          if (tagline != null) ...[
            const SizedBox(height: 10),
            Text(tagline,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 17,
                    fontStyle: FontStyle.italic,
                    color: Colors.white54)),
          ],
          if (overview != null) ...[
            const SizedBox(height: 16),
            overview,
          ],
          if (genres.isNotEmpty) ...[
            const SizedBox(height: 16),
            _genrePills(genres.take(4).toList(), size: 14),
          ],
          const SizedBox(height: 24),
          actions,
          if (progress != null) ...[
            const SizedBox(height: 18),
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                  width: 300,
                  child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          color: _red,
                          backgroundColor: Colors.white24))),
              if (progressLabel != null) ...[
                const SizedBox(width: 14),
                Text(progressLabel,
                    style:
                        const TextStyle(fontSize: 14, color: Colors.white60)),
              ],
            ]),
          ],
        ]);

/// En TV, cuando el foco entra en algo de [child] (el panel de Óscar, el botón "Corregir"...), la
/// pantalla se desplaza para que TODO el bloque se vea entero (carátula incluida) y no solo el
/// elemento enfocado, que dejaba la carátula cortada por abajo. Solo actúa con mando/teclado.
class _TvRevealOnFocus extends StatelessWidget {
  const _TvRevealOnFocus({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (has) {
          if (!has ||
              FocusManager.instance.highlightMode !=
                  FocusHighlightMode.traditional) {
            return;
          }
          // Después de que Flutter haya hecho su propio desplazamiento mínimo.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            Scrollable.ensureVisible(context,
                alignment: 0.5,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic);
          });
        },
        child: child,
      );
}

/// Lo secundario de la ficha en TV (debajo del cartel): carátula, premios, dirección y reparto.
/// [tail] va al final (datos del archivo, "Corregir"...).
Widget _tvAbout(Api api,
    {VideoItem? poster,
    required Profile pr,
    required String directorsLabel,
    List<Widget> tail = const []}) {
  final hasPoster = poster != null && poster.posterV > 0;
  return _TvRevealOnFocus(
      child: _tvWidth(
          true,
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 4, 56, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (hasPoster)
                Padding(
                    padding: const EdgeInsets.only(right: 28, top: 18),
                    child: PosterCard(
                        api: api,
                        item: poster!,
                        width: 140,
                        focusable: false,
                        onTap: () {})),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (pr.oscars.any)
                        Padding(
                            padding: const EdgeInsets.only(top: 14),
                            child: OscarBanner(pr.oscars)),
                      if (pr.directors.isNotEmpty)
                        _credit(directorsLabel, pr.directors.join(', '),
                            big: true),
                      if (pr.cast.isNotEmpty)
                        _credit('Reparto', pr.cast.join(', '), big: true),
                      ...tail,
                    ]),
              ),
            ]),
          )));
}

// ---------- detalle de la película ----------

class DetailScreen extends ConsumerWidget {
  const DetailScreen({super.key, required this.videoId});
  final String videoId;

  String? _runtime(Profile pr, VideoItem v) {
    final m = pr.runtime;
    if (m == null) return v.durationMs != null ? v.durationLabel : null;
    return m >= 60 ? '${m ~/ 60}h ${m % 60}m' : '${m}m';
  }

  /// Aviso de "este video aún no tiene carátula ni sinopsis" con sus botones.
  Widget _unmatchedCard(
          BuildContext context, Api api, VideoItem v, bool tmdb) =>
      Card(
        color: Colors.white10,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                tmdb
                    ? 'Este video aún no tiene carátula ni sinopsis.'
                    : 'El servidor no tiene clave de TMDB: añádela en su ventana para '
                        'obtener carátulas automáticamente, o edita el perfil a mano.',
                style: const TextStyle(fontSize: 16)),
            if (tmdb)
              Wrap(spacing: 8, children: [
                TextButton(
                    onPressed: () => _autoIdentify(context, api, v.id),
                    child: const Text('Identificar automáticamente')),
                TextButton(
                    onPressed: () => _searchTmdb(context, api, v),
                    child: const Text('Buscar en TMDB')),
              ]),
          ]),
        ),
      );

  /// Ficha de película para TV (mando a distancia, pantalla apaisada a 3 m):
  ///  - El cartel de arriba se ve igual que el del inicio (ver [_tvHero]): portada apaisada a
  ///    todo el ancho y la información encima, con Reproducir ya enfocado.
  ///  - Margen de seguridad de 56 px, letra mayor y sinopsis de 4 líneas (OK abre el texto
  ///    completo). Cast y "Más opciones" se ensanchan al enfocarlos.
  ///  - Lo secundario (carátula, premios, reparto, archivo y "Video") va debajo: ▼ para bajar.
  Widget _tvBody(BuildContext context, WidgetRef ref, Api api, VideoDetail det,
          bool tmdb) =>
      _TvMovieNav(
          builder: (ctx, play, video) =>
              _tvBodyWith(ctx, ref, api, det, tmdb, play, video));

  Widget _tvBodyWith(BuildContext context, WidgetRef ref, Api api,
      VideoDetail det, bool tmdb, FocusNode play, FocusNode video) {
    final v = det.item, pr = det.profile;
    final size = MediaQuery.of(context).size;
    final compact = size.height < 620;
    final year = pr.year ?? v.year;
    final rating = pr.rating ?? v.rating;
    final meta = <String>[
      if (year != null) '$year',
      if (_runtime(pr, v) != null) _runtime(pr, v)!,
      if (rating != null) '★\u00A0${rating.toStringAsFixed(1)}',
    ];
    final overview = pr.overview ?? v.overview;
    final unmatched = !pr.matched && v.posterV == 0;
    final backdrop = v.backdropV > 0 ? api.backdropUrl(v) : api.thumbUrl(v.id);

    final info = _tvInfo(
      eyebrow: 'PELÍCULA',
      title: v.title,
      meta: meta,
      age: AgeRatingBadge.maybe(pr.certification, pr.certCountry),
      tagline: pr.tagline,
      overview: unmatched
          ? _unmatchedCard(context, api, v, tmdb)
          : (overview != null && overview.isNotEmpty)
              ? _TvOverview(
                  title: v.title,
                  text: overview,
                  lines: compact ? 3 : 4,
                  // ▼ desde la sinopsis: al botón Reanudar/Reproducir.
                  onDown: () {
                    if (!tvUsable(play)) return false;
                    _tvJump(play);
                    return true;
                  })
              : null,
      genres: pr.genres.isNotEmpty ? pr.genres : v.genres,
      compact: compact,
      progress: v.progress,
      progressLabel: _remainingLabel(v),
      // ▼ desde Reanudar (o los botones de al lado): al video.
      actions: _TvKeyTo(
          keyId: LogicalKeyboardKey.arrowDown,
          onKey: () {
            if (!tvUsable(video)) return false;
            _tvJump(video);
            return true;
          },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _playButton(v.progress != null ? 'Reanudar' : 'Reproducir',
                () => playVideo(context, api, v),
                autofocus: true, large: true, focusNode: play),
            const SizedBox(width: 16),
            _TvActionButton(
                icon: Icons.cast_rounded,
                label: 'Ver en otro dispositivo',
                onTap: () => _playOn(context, ref, v)),
            const SizedBox(width: 16),
            _TvActionButton(
                icon: Icons.more_horiz_rounded,
                label: 'Más opciones',
                onTap: () => _options(context, ref, api, v)),
          ])),
    );

    return ListView(padding: EdgeInsets.zero, cacheExtent: 1500, children: [
      _tvHero(api, backdrop, size, info),
      Padding(
          padding: const EdgeInsets.fromLTRB(56, 20, 56, 0),
          child: _sectionTitle('Video')),
      // ▲ desde el video: al botón Reanudar/Reproducir.
      _TvKeyTo(
        keyId: LogicalKeyboardKey.arrowUp,
        onKey: () {
          if (!tvUsable(play)) return false;
          _tvJump(play);
          return true;
        },
        child: _TvEpisodeRow(
            count: 1,
            itemBuilder: (_, __) => _TvEpisodeCard(
                api: api,
                v: v,
                movie: true,
                focusNode: video,
                onTap: () => playVideo(context, api, v),
                onLong: () => _options(context, ref, api, v))),
      ),
      _tvAbout(api, poster: v, pr: pr, directorsLabel: 'Dirección', tail: [
        Padding(
            padding: const EdgeInsets.only(top: 22),
            child: Text(v.infoLabel,
                style: const TextStyle(color: Colors.white38, fontSize: 14))),
        if (pr.matched && tmdb)
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => _searchTmdb(context, api, v),
                  child: const Text('¿No es esta película? Corregir'))),
      ]),
      const SizedBox(height: 56),
    ]);
  }

  Widget _body(BuildContext context, WidgetRef ref, Api api, VideoDetail det,
      bool tmdb) {
    final v = det.item, pr = det.profile;
    final tv = ref.watch(tvModeProvider);
    // Películas en TV: ficha propia, de una sola pantalla (ver _tvBody).
    if (tv && !v.isEpisode) return _tvBody(context, ref, api, det, tmdb);
    final meta = <String>[
      if ((pr.year ?? v.year) != null) '${pr.year ?? v.year}',
      if (_runtime(pr, v) != null) _runtime(pr, v)!,
      if ((pr.rating ?? v.rating) != null)
        '★\u00A0${(pr.rating ?? v.rating)!.toStringAsFixed(1)}',
    ];
    final age = AgeRatingBadge.maybe(pr.certification, pr.certCountry);
    final overview = pr.overview ?? v.overview;
    final genres = pr.genres.isNotEmpty ? pr.genres : v.genres;
    final eyebrow = v.isEpisode
        ? '${v.show} · ${v.episodeLabel}'.toUpperCase()
        : 'PELÍCULA';

    return ListView(padding: EdgeInsets.zero, children: [
      _DetailHeader(
          api: api,
          url: v.backdropV > 0 ? api.backdropUrl(v) : api.thumbUrl(v.id),
          title: v.isEpisode ? (v.epTitle ?? v.title) : v.title,
          eyebrow: eyebrow),
      _tvWidth(
          tv,
          Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, v.isEpisode ? 36 : 8),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!v.isEpisode && pr.oscars.any)
                Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: OscarBanner(pr.oscars)),
              if (meta.isNotEmpty || age != null) _metaLine(meta, lead: age),
              if (pr.tagline != null)
                Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(pr.tagline!,
                        style: const TextStyle(
                            fontStyle: FontStyle.italic,
                            color: Colors.white54))),
              const SizedBox(height: 20),
              Row(children: [
                Flexible(
                    child: _playButton(
                        v.progress != null ? 'Reanudar' : 'Reproducir',
                        () => playVideo(context, api, v),
                        autofocus: tv)),
                const SizedBox(width: 12),
                _roundIcon(Icons.cast_rounded, 'Ver en otro dispositivo',
                    () => _playOn(context, ref, v)),
                // Con el mando no hay "mantener pulsado": las opciones salen con este botón.
                if (tv && !v.isEpisode) ...[
                  const SizedBox(width: 12),
                  _roundIcon(Icons.more_horiz_rounded, 'Más opciones',
                      () => _options(context, ref, api, v)),
                ],
              ]),
              if (v.isEpisode)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _ghostTheme(
                        context,
                        Wrap(spacing: 10, runSpacing: 10, children: [
                          DownloadButton(video: v),
                          OutlinedButton.icon(
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          ShowScreen(showId: v.showId!))),
                              icon: const Icon(Icons.format_list_numbered),
                              label: const Text('Todos los capítulos')),
                        ]))),
              if (v.progress != null)
                Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                            value: v.progress,
                            minHeight: 3,
                            color: _red,
                            backgroundColor: Colors.white12))),
              if (!pr.matched && v.posterV == 0) ...[
                const SizedBox(height: 20),
                Card(
                  color: Colors.white10,
                  elevation: 0,
                  margin: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tmdb
                              ? 'Este video aún no tiene carátula ni sinopsis.'
                              : 'El servidor no tiene clave de TMDB: añádela en su ventana para '
                                  'obtener carátulas automáticamente, o edita el perfil a mano.'),
                          if (tmdb)
                            Wrap(spacing: 8, children: [
                              TextButton(
                                  onPressed: () =>
                                      _autoIdentify(context, api, v.id),
                                  child: const Text(
                                      'Identificar automáticamente')),
                              TextButton(
                                  onPressed: () => _searchTmdb(context, api, v),
                                  child: const Text('Buscar en TMDB')),
                            ]),
                        ]),
                  ),
                ),
              ],
              if (v.posterV > 0 ||
                  (overview != null && overview.isNotEmpty)) ...[
                const SizedBox(height: 26),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (v.posterV > 0)
                    Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: PosterCard(
                            api: api,
                            item: v,
                            width: 104,
                            focusable: false,
                            onTap: () {})),
                  Expanded(child: _Overview(overview ?? '')),
                ]),
              ],
              if (genres.isNotEmpty) ...[
                const SizedBox(height: 22),
                _genrePills(genres),
              ],
              if (pr.directors.isNotEmpty)
                _credit('Dirección', pr.directors.join(', ')),
              if (pr.cast.isNotEmpty) _credit('Reparto', pr.cast.join(', ')),
              Padding(
                  padding: const EdgeInsets.only(top: 22),
                  child: Text(v.infoLabel,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12.5))),
              if (pr.matched && tmdb)
                Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: () => _searchTmdb(context, api, v),
                        child: Text(v.isEpisode
                            ? '¿No es esta serie? Corregir'
                            : '¿No es esta película? Corregir'))),
            ]),
          )),
      // Como en las series (que listan sus capítulos abajo), la película muestra su video:
      // imagen, duración, progreso y datos del archivo. Toca para reproducir; mantén
      // pulsado para más opciones.
      if (!v.isEpisode) ...[
        Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
            child: _sectionTitle('Video')),
        _EpisodeTile(
            api: api,
            v: v,
            movie: true,
            onTap: () => playVideo(context, api, v),
            onLong: () => _options(context, ref, api, v),
            trailing: EpisodeDownloadIcon(video: v)),
        const SizedBox(height: 36),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    if (api == null) return const SizedBox();
    final d = ref.watch(detailProvider(videoId));
    final tmdb = ref.watch(serverInfoProvider).valueOrNull?.tmdb ?? false;
    // En TV, la ficha de película va a pantalla completa y sin flecha (Atrás del mando).
    final hideBack = ref.watch(tvModeProvider) &&
        !_tvShowBack &&
        !(d.valueOrNull?.item.isEpisode ?? false);
    return Scaffold(
      backgroundColor: _bg,
      extendBodyBehindAppBar: true,
      appBar: hideBack
          ? null
          : AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leadingWidth: 60,
              leading: const _GlassBack(),
            ),
      body: d.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _red)),
        error: (e, _) => Center(child: Text(errText(e))),
        data: (det) => _body(context, ref, api, det, tmdb),
      ),
    );
  }
}

// ---------- editor de perfil ----------

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key, required this.api, required this.detail});
  final Api api;
  final VideoDetail detail;
  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final VideoItem _v = widget.detail.item;
  late final Profile _p = widget.detail.profile;
  late final _title =
      TextEditingController(text: _p.title ?? _v.epTitle ?? _v.title);
  late final _year = TextEditingController(text: '${_p.year ?? _v.year ?? ''}');
  late final _rating =
      TextEditingController(text: '${_p.rating ?? _v.rating ?? ''}');
  late final _runtime = TextEditingController(text: '${_p.runtime ?? ''}');
  late final _tagline = TextEditingController(text: _p.tagline ?? '');
  late final _cert = TextEditingController(text: _p.certification ?? '');
  late final _genres = TextEditingController(
      text: (_p.genres.isNotEmpty ? _p.genres : _v.genres).join(', '));
  late final _directors = TextEditingController(text: _p.directors.join(', '));
  late final _cast = TextEditingController(text: _p.cast.join(', '));
  late final _overview =
      TextEditingController(text: _p.overview ?? _v.overview ?? '');
  final _posterUrl = TextEditingController();
  final _backdropUrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _title,
      _year,
      _rating,
      _runtime,
      _tagline,
      _cert,
      _genres,
      _directors,
      _cast,
      _overview,
      _posterUrl,
      _backdropUrl
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
      .showSnackBar(errorSnack(m)); // solo se usa para errores

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.api.saveProfile(_v.id, {
        'title': _title.text,
        'year': _year.text,
        'rating': _rating.text,
        'runtime': _runtime.text,
        'tagline': _tagline.text,
        'certification': _cert.text,
        'genres': _genres.text,
        'directors': _directors.text,
        'cast': _cast.text,
        'overview': _overview.text,
        if (_posterUrl.text.trim().isNotEmpty)
          'posterUrl': _posterUrl.text.trim(),
        if (_backdropUrl.text.trim().isNotEmpty)
          'backdropUrl': _backdropUrl.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(errText(e));
    }
  }

  Future<void> _reset() async {
    Sfx.play(Snd.alerta, force: true);
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Restablecer perfil'),
              content: const Text(
                  'Se borrarán carátula, sinopsis y demás datos. El video volverá a mostrarse con el nombre del archivo.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancelar')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Restablecer')),
              ],
            ));
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await widget.api.resetProfile(_v.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack(errText(e));
    }
  }

  Future<void> _tmdb() async {
    final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => TmdbSearchScreen(api: widget.api, item: _v)));
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  Widget _f(TextEditingController c, String label,
          {int maxLines = 1, TextInputType? type, String? helper}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TvTextEntry(
              multiline: maxLines > 1,
              child: TextField(
                  controller: c,
                  maxLines: maxLines,
                  keyboardType: type,
                  decoration: InputDecoration(
                      labelText: label,
                      helperText: helper,
                      border: const OutlineInputBorder()))));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Editar perfil'), actions: [
        TextButton(
            onPressed: _busy ? null : _save, child: const Text('Guardar')),
      ]),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (_busy) const LinearProgressIndicator(),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PosterCard(
                api: widget.api,
                item: _v,
                width: 90,
                focusable: false,
                onTap: () {}),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  FilledButton.icon(
                      onPressed: _tmdb,
                      icon: const Icon(Icons.travel_explore),
                      label: const Text('Buscar en TMDB')),
                  const SizedBox(height: 8),
                  const Text(
                      'Elige la ficha correcta y se descargan carátula, fondo, sinopsis, valoración y reparto. Después puedes retocar cualquier campo.',
                      style: TextStyle(color: Colors.white60, fontSize: 12)),
                ])),
          ]),
          const SizedBox(height: 20),
          _f(_title, 'Título'),
          Row(children: [
            Expanded(child: _f(_year, 'Año', type: TextInputType.number)),
            const SizedBox(width: 12),
            Expanded(
                child: _f(_rating, 'Valoración (0-10)',
                    type:
                        const TextInputType.numberWithOptions(decimal: true))),
            const SizedBox(width: 12),
            Expanded(
                child: _f(_runtime, 'Minutos', type: TextInputType.number)),
          ]),
          _f(_tagline, 'Lema'),
          _f(_cert, 'Clasificación de edades',
              helper: 'Ej.: A, B, B15, C, PG-13, R, TV-MA, 12, 16'),
          _f(_genres, 'Géneros', helper: 'Separados por comas'),
          _f(_directors, 'Dirección', helper: 'Separados por comas'),
          _f(_cast, 'Reparto', helper: 'Separados por comas'),
          _f(_overview, 'Sinopsis', maxLines: 6),
          _f(_posterUrl, 'URL de carátula propia (opcional)',
              type: TextInputType.url,
              helper: 'El servidor descarga la imagen y la guarda'),
          _f(_backdropUrl, 'URL de fondo propio (opcional)',
              type: TextInputType.url),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              style:
                  OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
              onPressed: _reset,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Restablecer perfil')),
        ]),
      ),
    );
  }
}

// ---------- búsqueda en TMDB ----------

({String title, int? year}) _guess(String raw) {
  var s = raw
      .replaceAll(RegExp(r'[._]+'), ' ')
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
  int? year;
  final m = RegExp(r'[\(\s]((?:19|20)\d{2})(?=[\)\s]|$)')
      .allMatches(s)
      .where((x) => x.start > 0)
      .toList();
  if (m.isNotEmpty) {
    year = int.parse(m.last.group(1)!);
    s = s.substring(0, m.last.start);
  }
  s = s
      .replaceAll(RegExp(r'[\(\)\-]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return (title: s, year: year);
}

class TmdbSearchScreen extends StatefulWidget {
  const TmdbSearchScreen({super.key, required this.api, required this.item});
  final Api api;
  final VideoItem item;
  @override
  State<TmdbSearchScreen> createState() => _TmdbSearchScreenState();
}

class _TmdbSearchScreenState extends State<TmdbSearchScreen> {
  late final TextEditingController _q;
  late final TextEditingController _year;
  List<TmdbCandidate> _results = const [];
  bool _loading = false, _applying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final g = _guess(widget.item.show ?? widget.item.title);
    _q = TextEditingController(text: g.title);
    _year = TextEditingController(
        text:
            '${g.year ?? (widget.item.isEpisode ? null : widget.item.year) ?? ''}');
    _run();
  }

  @override
  void dispose() {
    _q.dispose();
    _year.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_q.text.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.api.tmdbSearch(_q.text.trim(),
          year: int.tryParse(_year.text.trim()),
          type: (widget.item.isShow || widget.item.isEpisode) ? 'tv' : null);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = errText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pick(TmdbCandidate c) async {
    setState(() => _applying = true);
    try {
      await widget.api.matchProfile(widget.item.id, c.id, c.type);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _applying = false);
      ScaffoldMessenger.of(context).showSnackBar(errorSnack(errText(e)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Buscar en TMDB')),
      body: Column(children: [
        if (_loading || _applying) const LinearProgressIndicator(),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
                child: TvTextEntry(
                    child: TextField(
                        controller: _q,
                        textInputAction: TextInputAction.search,
                        decoration: const InputDecoration(
                            labelText: 'Título', border: OutlineInputBorder()),
                        onSubmitted: (_) => _run()))),
            const SizedBox(width: 8),
            SizedBox(
                width: 80,
                child: TvTextEntry(
                    child: TextField(
                        controller: _year,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Año', border: OutlineInputBorder()),
                        onSubmitted: (_) => _run()))),
            IconButton(icon: const Icon(Icons.search), onPressed: _run),
          ]),
        ),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.redAccent))),
        Expanded(
          child: AbsorbPointer(
            absorbing: _applying,
            child: _results.isEmpty && !_loading && _error == null
                ? const Center(
                    child: Text('Sin resultados. Prueba otro título.'))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final c = _results[i];
                      return ListTile(
                        leading: SizedBox(
                            width: 46,
                            height: 69,
                            child: c.posterUrl != null
                                ? Image.network(c.posterUrl!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Icon(Icons.movie))
                                : const Icon(Icons.movie)),
                        title: Text(
                            '${c.title}${c.year != null ? ' (${c.year})' : ''}'),
                        subtitle: Text(
                            '${c.type == 'tv' ? 'Serie' : 'Película'}'
                            '${c.rating != null && c.rating! > 0 ? ' · ★ ${c.rating!.toStringAsFixed(1)}' : ''}'
                            '${(c.overview ?? '').isEmpty ? '' : '\n${c.overview}'}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis),
                        isThreeLine: (c.overview ?? '').isNotEmpty,
                        onTap: () => _pick(c),
                      );
                    }),
          ),
        ),
      ]),
    );
  }
}

// ===========================================================================
//  Series: ficha con todos los capítulos, agrupados por temporada (como Plex).
// ===========================================================================

/// Reproduce el capítulo que toca ver (el que dejaste a medias o el siguiente al último visto).
Future<void> _playNext(BuildContext context, Api api, String showId) async {
  try {
    final d = await api.show(showId);
    if (d.episodes.isEmpty || !context.mounted) return;
    final v = d.episodes.firstWhere((e) => e.id == d.show.nextId,
        orElse: () => d.episodes.first);
    await playVideo(context, api, v);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(errorSnack(errText(e)));
    }
  }
}

void _showOptions(BuildContext context, WidgetRef ref, Api api, VideoItem s) {
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
            title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: const Text('Serie')),
        ListTile(
            leading: const Icon(Icons.format_list_numbered),
            title: const Text('Ver capítulos'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => ShowScreen(showId: s.id)));
            }),
        ListTile(
            leading: const Icon(Icons.play_arrow),
            title: const Text('Reproducir siguiente capítulo'),
            onTap: () {
              Navigator.pop(ctx);
              _playNext(context, api, s.id);
            }),
        ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Descargar capítulos...'),
            onTap: () async {
              Navigator.pop(ctx);
              try {
                final d = await api.show(s.id);
                if (context.mounted) showShowDownloadSheet(context, ref, d);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(errorSnack(errText(e)));
                }
              }
            }),
        /*ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Editar perfil'),
            onTap: () {
              Navigator.pop(ctx);
              editProfile(context, api, s.id);
            }),*/
        ListTile(
            leading: const Icon(Icons.travel_explore),
            title: const Text('Buscar en TMDB'),
            onTap: () {
              Navigator.pop(ctx);
              _searchTmdb(context, api, s);
            }),
      ]),
    ),
  );
}

class ShowScreen extends ConsumerStatefulWidget {
  const ShowScreen({super.key, required this.showId});
  final String showId;
  @override
  ConsumerState<ShowScreen> createState() => _ShowScreenState();
}

class _ShowScreenState extends ConsumerState<ShowScreen> {
  int? _season; // null = todas las temporadas
  bool _seasonInit = false; // la temporada inicial se elige una sola vez

  // --- Modo TV ---
  final _outer = ScrollController();
  final _playNode = FocusNode(debugLabel: 'ShowPlay');
  // Barra de pestañas de temporada: al enfocarla la pantalla se desplaza para dejarla arriba.
  final _chipsKey = GlobalKey(debugLabel: 'ShowSeasonChips');
  final _nodes = <String, FocusNode>{}; // un nodo de foco por capítulo
  final _rowCtrls =
      <int, ScrollController>{}; // un desplazamiento por fila (temporada)
  String? _lastEp; // último capítulo que tuvo el foco: ▼ vuelve a él
  // Último capítulo enfocado de CADA temporada: al subir o bajar entre filas (o a una
  // temporada distinta con las pestañas) el foco vuelve al capítulo que tenías en esa fila.
  final _lastBySeason = <int, String>{};
  // Un nodo por fila (invisible) para saber si el foco está en ella y como red de seguridad.
  final _rowNodes = <int, FocusNode>{};
  bool _scrolled = false;

  // Las fichas se abren con Navigator.push, FUERA del grupo de foco del shell, así que la
  // política de TV (◀▶ estrictos por fila) no les llega: con la de Flutter, ▶ en el último
  // capítulo de una temporada saltaba a la fila de la siguiente. Se instala aquí.
  final _policy = TvTraversalPolicy();

  FocusNode _rowNode(int season) => _rowNodes.putIfAbsent(
      season,
      () => FocusNode(
          debugLabel: 'season-$season',
          canRequestFocus: false,
          skipTraversal: true));

  FocusNode _node(String id) =>
      _nodes.putIfAbsent(id, () => FocusNode(debugLabel: 'ep-$id'));

  @override
  void initState() {
    super.initState();
    _markNewsSeen();
    _outer.addListener(() {
      final s = _outer.hasClients && _outer.offset > 80;
      if (s != _scrolled && mounted) setState(() => _scrolled = s);
    });
  }

  @override
  void dispose() {
    _outer.dispose();
    _playNode.dispose();
    for (final n in _nodes.values) {
      n.dispose();
    }
    for (final c in _rowCtrls.values) {
      c.dispose();
    }
    for (final n in _rowNodes.values) {
      n.dispose();
    }
    super.dispose();
  }

  ScrollController _rowCtrl(int season, int initialIndex) => _rowCtrls.putIfAbsent(
      season,
      // Recuerda su posición: si la fila se descarta por estar lejos y se reconstruye, vuelve
      // a donde la dejaste (no al capítulo que toca ver).
      () => _ShelfScroll(_TvEpisodeRow.offsetFor(initialIndex)));

  /// ▼ hacia los capítulos: enfoca el último que tenías; si no hay, el que toca ver; si no, el
  /// primero. Las filas son perezosas: si esa tarjeta ya no está construida (estaba lejos en la
  /// fila) se desplaza la fila hasta ella y se enfoca en cuanto aparece. Antes, desde el capítulo
  /// 4 en adelante ▼ no hacía nada porque el destino no existía.
  bool _goToEpisode(
      List<int> shown, Map<int, List<VideoItem>> bySeason, VideoItem? next) {
    String? id;
    int? season;
    int idx = 0;
    bool find(String? want) {
      if (want == null) return false;
      for (final n in shown) {
        final i = (bySeason[n] ?? const <VideoItem>[])
            .indexWhere((e) => e.id == want);
        if (i >= 0) {
          id = want;
          season = n;
          idx = i;
          return true;
        }
      }
      return false;
    }

    if (!find(_lastEp)) {
      // Sin capítulo recordado en lo que se muestra: el recordado de la primera temporada
      // visible, si no el que toca ver, si no el primero.
      for (final n in shown) {
        final eps = bySeason[n];
        if (eps == null || eps.isEmpty) continue;
        if (!find(_lastBySeason[n]) && !find(next?.id)) {
          id = eps.first.id;
          season = n;
          idx = 0;
        }
        break;
      }
    }
    if (id == null || season == null) return false;
    return _focusEpisode(season!, idx, id!);
  }

  /// Lleva el foco al capítulo [id] (posición [idx]) de la fila de la temporada [season]. Si su
  /// tarjeta no está construida se desplaza la fila hasta ella y se enfoca en cuanto aparece.
  bool _focusEpisode(int season, int idx, String id) {
    final node = _node(id);
    final row = _rowNode(season);
    final before = FocusManager.instance.primaryFocus;
    if (tvUsable(node)) {
      _tvJump(node);
      _tvEnsureIn(before, row);
      return true;
    }
    final ctrl = _rowCtrls[season];
    if (ctrl == null || !ctrl.hasClients) return false;
    final max = ctrl.position.maxScrollExtent;
    ctrl.jumpTo(_TvEpisodeRow.offsetFor(idx).clamp(0.0, max).toDouble());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && tvUsable(node)) _tvJump(node);
      _tvEnsureIn(before, row);
    });
    return true;
  }

  /// ▲▼ entre filas de temporadas: al capítulo que tenías en la fila [n]; si nunca entraste, al
  /// que toca ver (si es de esa temporada) o al primero.
  bool _focusSeasonRow(int n, List<VideoItem> eps, VideoItem? next) {
    if (eps.isEmpty) return false;
    var idx = _lastBySeason[n] == null
        ? -1
        : eps.indexWhere((e) => e.id == _lastBySeason[n]);
    if (idx < 0) {
      idx = next != null && (next.season ?? 0) == n
          ? math.max(0, eps.indexWhere((e) => e.id == next.id))
          : 0;
    }
    return _focusEpisode(n, idx, eps[idx].id);
  }

  /// ▲ desde las pestañas de temporada: el foco va al botón Reanudar/Reproducir y la pantalla
  /// vuelve arriba para enseñar el cartel entero.
  bool _chipsUp() {
    if (!tvUsable(_playNode)) return false;
    _tvJump(_playNode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_outer.hasClients) return;
      _outer.animateTo(0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic);
    });
    WidgetsBinding.instance.scheduleFrame();
    return true;
  }

  /// Al entrar el foco en las pestañas (con ▼ desde Reanudar o ▲ desde los capítulos) la
  /// pantalla se desplaza hasta dejar las pestañas arriba: así se ven a la vez las temporadas,
  /// el título de la primera fila y esa fila de capítulos (en vez del mínimo que asoma la barra).
  void _revealChips(bool has) {
    if (!has ||
        FocusManager.instance.highlightMode != FocusHighlightMode.traditional) {
      return;
    }
    // Después de que Flutter haya hecho su propio desplazamiento mínimo.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _chipsKey.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(ctx,
          alignment: 0.0,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic);
    });
  }

  /// Atrás con el mando estando abajo: primero vuelve arriba (a Reproducir) y, con otro Atrás,
  /// sale de la ficha (como las apps de streaming).
  void _backToTop() {
    if (!_outer.hasClients) return;
    _outer
        .animateTo(0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic)
        .whenComplete(() {
      if (mounted) _playNode.requestFocus();
    });
  }

  /// Abrir la serie cuenta como abrir su novedad: se apaga el punto de la campanita.
  /// (Los capítulos siguen marcados como NUEVO hasta que los veas.)
  Future<void> _markNewsSeen() async {
    try {
      final data = await ref.read(newsProvider.future);
      if (!mounted) return;
      if (!data.items.any((i) => i.showId == widget.showId && i.unread)) return;
      final api = ref.read(apiProvider);
      if (api == null) return;
      await api.markNewsRead(showId: widget.showId);
      if (mounted) ref.invalidate(newsProvider);
    } catch (_) {}
  }

  static String _seasonName(int s) => s == 0 ? 'Especiales' : 'Temporada $s';

  Widget _top(Api api, ShowDetail det, bool tmdb, List<int> seasons) {
    final s = det.show, pr = det.profile, card = s.toCard();
    final next = det.episodes.isEmpty
        ? null
        : det.episodes.firstWhere((e) => e.id == s.nextId,
            orElse: () => det.episodes.first);
    final meta = <String>[
      if ((pr.year ?? s.year) != null) '${pr.year ?? s.year}',
      '${s.seasons} ${s.seasons == 1 ? 'temporada' : 'temporadas'}',
      if ((pr.rating ?? s.rating) != null)
        '★\u00A0${(pr.rating ?? s.rating)!.toStringAsFixed(1)}',
    ];
    final overview = pr.overview ?? s.overview;
    final genres = pr.genres.isNotEmpty ? pr.genres : s.genres;
    final resuming =
        next != null && next.progress != null && next.progress! < 0.95;
    final playLabel = next == null
        ? 'Reproducir'
        : '${resuming ? 'Reanudar' : 'Reproducir'} ${next.episodeLabel}';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _DetailHeader(
          api: api,
          url: s.backdropV > 0
              ? api.backdropUrl(card)
              : api.thumbUrl(
                  det.episodes.isEmpty ? s.id : det.episodes.first.id),
          title: s.name,
          eyebrow: 'SERIE'),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (pr.oscars.any)
            Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: OscarBanner(pr.oscars)),
          _metaLine(meta,
              lead: AgeRatingBadge.maybe(pr.certification, pr.certCountry)),
          if (pr.tagline != null)
            Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(pr.tagline!,
                    style: const TextStyle(
                        fontStyle: FontStyle.italic, color: Colors.white54))),
          const SizedBox(height: 20),
          if (next != null)
            Row(children: [
              Flexible(
                  child: _playButton(
                      playLabel, () => playVideo(context, api, next),
                      autofocus: ref.watch(tvModeProvider))),
              const SizedBox(width: 12),
              _roundIcon(Icons.cast_rounded, 'Ver en otro dispositivo',
                  () => _playOn(context, ref, next)),
            ]),
          if (s.posterV > 0 || (overview != null && overview.isNotEmpty)) ...[
            const SizedBox(height: 26),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (s.posterV > 0)
                Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: PosterCard(
                        api: api,
                        item: card,
                        width: 104,
                        focusable: false,
                        onTap: () {})),
              Expanded(child: _Overview(overview ?? '')),
            ]),
          ],
          if (genres.isNotEmpty) ...[
            const SizedBox(height: 22),
            _genrePills(genres),
          ],
          if (pr.directors.isNotEmpty)
            _credit('Creada por', pr.directors.join(', ')),
          if (pr.cast.isNotEmpty) _credit('Reparto', pr.cast.join(', ')),
          if (s.matched && tmdb)
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => _searchTmdb(context, api, card),
                    child: const Text('¿No es esta serie? Corregir'))),
        ]),
      ),
      if (seasons.length > 1)
        SizedBox(
          height: 54,
          child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              children: [
                _seasonChip('Todas', _season == null,
                    () => setState(() => _season = null)),
                for (final n in seasons)
                  _seasonChip(_seasonName(n), _season == n,
                      () => setState(() => _season = n)),
              ]),
        ),
    ]);
  }

  /// Ficha de serie para TV:
  ///  - Cartel igual que el del inicio ([_tvHero]) con Reanudar/Reproducir enfocado.
  ///  - Temporadas (si hay varias) y, debajo, los capítulos en FILAS HORIZONTALES de tarjetas 16:9.
  ///    Con "Todas" salen una fila por temporada.
  ///  - ▼ desde Reproducir (o desde las temporadas) va directo al capítulo que toca ver, y la
  ///    fila se abre centrada en él; ◀▶ recorre la fila y ▲ vuelve.
  ///  - Atrás estando abajo sube primero al cartel.
  ///  - Los datos secundarios (carátula, creadores, reparto) quedan al final.
  Widget _tvSeriesBody(Api api, ShowDetail det, bool tmdb, List<int> seasons,
      int? season, Map<int, List<VideoItem>> bySeason) {
    final s = det.show, pr = det.profile, card = s.toCard();
    final size = MediaQuery.of(context).size;
    final compact = size.height < 620;
    final fresh =
        ref.watch(newsProvider).valueOrNull?.newEpisodeIds(widget.showId) ??
            const <String>{};
    final next = det.episodes.isEmpty
        ? null
        : det.episodes.firstWhere((e) => e.id == s.nextId,
            orElse: () => det.episodes.first);
    final year = pr.year ?? s.year;
    final rating = pr.rating ?? s.rating;
    final meta = <String>[
      if (year != null) '$year',
      '${s.seasons} ${s.seasons == 1 ? 'temporada' : 'temporadas'}',
      if (rating != null) '★\u00A0${rating.toStringAsFixed(1)}',
    ];
    final overview = pr.overview ?? s.overview;
    final resuming =
        next != null && next.progress != null && next.progress! < 0.95;
    final playLabel = next == null
        ? 'Reproducir'
        : '${resuming ? 'Reanudar' : 'Reproducir'} ${next.episodeLabel}';
    final shown = season == null ? seasons : [season];
    final hasChips = seasons.length > 1;

    bool goDown() => _goToEpisode(shown, bySeason, next);

    // ▲ desde la PRIMERA fila de capítulos: al botón Reanudar (con pestañas de temporada, ▲
    // sube primero a ellas, como siempre).
    final firstSeason = shown.cast<int?>().firstWhere(
        (n) => (bySeason[n] ?? const <VideoItem>[]).isNotEmpty,
        orElse: () => null);
    // Filas con capítulos, en orden: ▲▼ entre ellas llevan al capítulo recordado de la vecina.
    final filled = [
      for (final n in shown)
        if ((bySeason[n] ?? const <VideoItem>[]).isNotEmpty) n
    ];
    Widget upToPlay(int n, Widget row) {
      final k = filled.indexOf(n);
      return _TvKeyTo(
          keyId: LogicalKeyboardKey.arrowUp,
          enabled: k > 0,
          onKey: () =>
              _focusSeasonRow(filled[k - 1], bySeason[filled[k - 1]]!, next),
          child: _TvKeyTo(
              keyId: LogicalKeyboardKey.arrowDown,
              enabled: k >= 0 && k < filled.length - 1,
              onKey: () => _focusSeasonRow(
                  filled[k + 1], bySeason[filled[k + 1]]!, next),
              child: _TvKeyTo(
                  keyId: LogicalKeyboardKey.arrowUp,
                  enabled: !hasChips && n == firstSeason,
                  onKey: () {
                    if (!tvUsable(_playNode)) return false;
                    _tvJump(_playNode);
                    return true;
                  },
                  child: Focus(
                      focusNode: _rowNode(n),
                      canRequestFocus: false,
                      skipTraversal: true,
                      child: row))));
    }

    final info = _tvInfo(
      eyebrow: 'SERIE',
      title: s.name,
      meta: meta,
      age: AgeRatingBadge.maybe(pr.certification, pr.certCountry),
      tagline: pr.tagline,
      overview: (overview != null && overview.isNotEmpty)
          ? _TvOverview(
              title: s.name,
              text: overview,
              lines: compact ? 3 : 4,
              // ▼ desde la sinopsis: al botón Reanudar/Reproducir.
              onDown: () {
                if (!tvUsable(_playNode)) return false;
                _tvJump(_playNode);
                return true;
              })
          : null,
      genres: pr.genres.isNotEmpty ? pr.genres : s.genres,
      compact: compact,
      progress: resuming ? next!.progress : null,
      progressLabel: resuming ? _remainingLabel(next!) : null,
      actions: _TvDownTo(
        onDown: goDown,
        enabled: !hasChips,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (next != null) ...[
            _playButton(playLabel, () => playVideo(context, api, next),
                autofocus: true, large: true, focusNode: _playNode),
            const SizedBox(width: 16),
            _TvActionButton(
                icon: Icons.cast_rounded,
                label: 'Ver en otro dispositivo',
                onTap: () => _playOn(context, ref, next)),
          ],
        ]),
      ),
    );

    final rows = <Widget>[
      for (final n in shown)
        if ((bySeason[n] ?? const <VideoItem>[]).isNotEmpty) ...[
          _tvSeasonTitle(n, bySeason[n]!),
          upToPlay(
              n,
              _TvEpisodeRow(
                key: ValueKey('season-$n'),
                count: bySeason[n]!.length,
                // Abre ya centrada en el capítulo que toca ver (si es de esta temporada).
                controller: _rowCtrl(
                    n,
                    next == null || (next.season ?? 0) != n
                        ? 0
                        : math.max(0,
                            bySeason[n]!.indexWhere((e) => e.id == next.id))),
                itemBuilder: (ctx, i) {
                  final v = bySeason[n]![i];
                  return _TvEpisodeCard(
                      key: ValueKey(v.id),
                      api: api,
                      v: v,
                      focusNode: _node(v.id),
                      onFocused: () {
                        _lastEp = v.id;
                        _lastBySeason[n] = v.id;
                      },
                      isNew: fresh.contains(v.id),
                      onTap: () => playVideo(context, api, v),
                      onLong: () => _options(context, ref, api, v));
                },
              )),
        ],
    ];

    return ListView(controller: _outer, padding: EdgeInsets.zero, children: [
      _tvHero(
          api,
          s.backdropV > 0
              ? api.backdropUrl(card)
              : api.thumbUrl(
                  det.episodes.isEmpty ? s.id : det.episodes.first.id),
          size,
          info),
      if (hasChips)
        // ▲ desde las pestañas: al botón Reanudar. ▼: al capítulo que toca. Al enfocarlas se
        // muestran junto con la primera fila de capítulos.
        _TvKeyTo(
          keyId: LogicalKeyboardKey.arrowUp,
          onKey: _chipsUp,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: _revealChips,
            child: _TvDownTo(
              onDown: goDown,
              child: SizedBox(
                key: _chipsKey,
                height: 64,
                child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 56, vertical: 12),
                    children: [
                      _seasonChip('Todas', _season == null,
                          () => setState(() => _season = null),
                          tv: true),
                      for (final n in seasons)
                        _seasonChip(_seasonName(n), _season == n,
                            () => setState(() => _season = n),
                            tv: true),
                    ]),
              ),
            ),
          ),
        ),
      ...rows,
      _tvAbout(api, poster: card, pr: pr, directorsLabel: 'Creada por', tail: [
        if (s.matched && tmdb)
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => _searchTmdb(context, api, card),
                  child: const Text('¿No es esta serie? Corregir'))),
      ]),
      const SizedBox(height: 56),
    ]);
  }

  /// Título de la fila de una temporada: "Temporada 1 · 2 capítulos · 1 visto".
  Widget _tvSeasonTitle(int n, List<VideoItem> eps) {
    final seen =
        eps.where((v) => v.progress != null && v.progress! >= 0.95).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 14, 56, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
            width: 3,
            height: 22,
            decoration: BoxDecoration(
                color: _red, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 12),
        Text(_seasonName(n),
            style: const TextStyle(
                fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
        const SizedBox(width: 14),
        Text(
            [
              '${eps.length} ${eps.length == 1 ? 'capítulo' : 'capítulos'}',
              if (seen > 0) '$seen ${seen == 1 ? 'visto' : 'vistos'}',
            ].join(' · '),
            style: const TextStyle(color: Colors.white54, fontSize: 14)),
      ]),
    );
  }

  Widget _body(Api api, ShowDetail det, bool tmdb) {
    final seasons = ({for (final e in det.episodes) e.season ?? 0}.toList())
      ..sort();
    // Con varias temporadas se abre en la que toca ver (la del capítulo que sigue), como
    // Plex; "Todas" sigue a un toque en las pestañas.
    if (!_seasonInit) {
      _seasonInit = true;
      final ns = det.show.nextSeason;
      if (seasons.length > 1 && ns != null && seasons.contains(ns))
        _season = ns;
    }
    // Si la temporada elegida ya no existe (se borraron archivos), se muestran todas.
    final season = seasons.contains(_season) ? _season : null;
    // Capítulos de cada temporada (para el encabezado: cuántos, cuántos vistos, acciones).
    final bySeason = <int, List<VideoItem>>{};
    for (final e in det.episodes) {
      (bySeason[e.season ?? 0] ??= []).add(e);
    }
    final rows =
        <Object>[]; // int = encabezado de temporada, VideoItem = capítulo
    int? last;
    for (final e in det.episodes) {
      final sn = e.season ?? 0;
      if (season != null && sn != season) continue;
      if (sn != last) {
        rows.add(sn);
        last = sn;
      }
      rows.add(e);
    }
    // En TV: cartel + capítulos en filas horizontales (ver _tvSeriesBody).
    if (ref.watch(tvModeProvider)) {
      return _tvSeriesBody(api, det, tmdb, seasons, season, bySeason);
    }
    final top = _top(api, det, tmdb, seasons);
    final fresh =
        ref.watch(newsProvider).valueOrNull?.newEpisodeIds(widget.showId) ??
            const <String>{};

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: rows.length + 2,
      itemBuilder: (ctx, i) {
        if (i == 0) return top;
        if (i == rows.length + 1) return const SizedBox(height: 32);
        final r = rows[i - 1];
        if (r is int) {
          final eps = bySeason[r] ?? const <VideoItem>[];
          final seen = eps
              .where((v) => v.progress != null && v.progress! >= 0.95)
              .length;
          // Reproducir: el primero sin ver de la temporada (o el primero, si la viste toda).
          final toPlay = eps.isEmpty
              ? null
              : eps.firstWhere((v) => v.progress == null || v.progress! < 0.95,
                  orElse: () => eps.first);
          return _SeasonHeader(
            name: _seasonName(r),
            count: eps.length,
            seen: seen,
            playLabel: toPlay?.episodeLabel,
            onPlay:
                toPlay == null ? null : () => playVideo(context, api, toPlay),
            onDownload: () =>
                askDownloadMany(context, ref, eps, _seasonName(r)),
          );
        }
        final v = r as VideoItem;
        return _EpisodeTile(
            api: api,
            v: v,
            isNew: fresh.contains(v.id),
            onTap: () => playVideo(context, api, v),
            onLong: () => _options(context, ref, api, v),
            trailing: EpisodeDownloadIcon(video: v));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiProvider);
    if (api == null) return const SizedBox();
    final d = ref.watch(showDetailProvider(widget.showId));
    final tmdb = ref.watch(serverInfoProvider).valueOrNull?.tmdb ?? false;
    final tvMode = ref.watch(tvModeProvider);
    final hideBack = tvMode && !_tvShowBack;
    return PopScope(
        // En TV, estando abajo, Atrás primero sube al cartel (ver _backToTop).
        canPop: !(tvMode && _scrolled),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _backToTop();
        },
        child: Scaffold(
          backgroundColor: _bg,
          extendBodyBehindAppBar: true,
          appBar: hideBack
              ? null
              : AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  leadingWidth: 60,
                  leading: const _GlassBack(),
                ),
          body: _tvGroup(
            tvMode,
            _policy,
            d.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator(color: _red)),
              error: (e, _) => Center(child: Text(errText(e))),
              data: (det) => _body(api, det, tmdb),
            ),
          ),
        ));
  }
}

/// Encabezado de una temporada dentro de la ficha de la serie: nombre, cuántos capítulos
/// hay y cuántos has visto, y los botones de reproducir y descargar esa temporada.
class _SeasonHeader extends StatelessWidget {
  const _SeasonHeader(
      {required this.name,
      required this.count,
      required this.seen,
      required this.onDownload,
      this.playLabel,
      this.onPlay});
  final String name;
  final int count, seen;
  final String? playLabel;
  final VoidCallback? onPlay;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final info = [
      '$count ${count == 1 ? 'capítulo' : 'capítulos'}',
      if (seen > 0) '$seen ${seen == 1 ? 'visto' : 'vistos'}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 12, 6),
      child: Row(children: [
        Container(
            width: 3,
            height: 34,
            decoration: BoxDecoration(
                color: _red, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 10),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2)),
            const SizedBox(height: 2),
            Text(info,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ]),
        ),
        if (onPlay != null)
          IconButton(
              style: IconButton.styleFrom(backgroundColor: Colors.white10),
              icon: const Icon(Icons.play_arrow_rounded),
              tooltip: playLabel == null
                  ? 'Reproducir temporada'
                  : 'Reproducir $playLabel',
              onPressed: onPlay),
        IconButton(
            icon: const Icon(Icons.download_rounded, color: Colors.white70),
            tooltip: 'Descargar $name',
            onPressed: onDownload),
      ]),
    );
  }
}

/// Fila de un capítulo: imagen, "N. Nombre", duración, progreso y sinopsis.
class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile(
      {required this.api,
      required this.v,
      required this.onTap,
      required this.onLong,
      this.trailing,
      this.isNew = false,
      this.movie = false,
      this.radius = 0});
  final Api api;
  final VideoItem v;
  final VoidCallback onTap, onLong;

  /// Radio de las esquinas del resalte (en TV coincide con el del aro de foco).
  final double radius;

  /// Capítulo que llegó después de que la serie ya estuviera en la biblioteca y no has visto.
  final bool isNew;

  /// Widget al final de la fila (icono de descarga del capítulo).
  final Widget? trailing;

  /// Fila del video de una película: sin número de capítulo ni sinopsis (ya sale arriba)
  /// y con los datos del archivo (calidad, tamaño...).
  final bool movie;

  @override
  Widget build(BuildContext context) {
    final done = v.progress != null && v.progress! >= 0.95;
    final meta = [
      if (v.durationMs != null) v.durationLabel,
      if (done) 'Visto',
    ];
    final overview = movie ? null : v.overview;
    // Datos del archivo (la duración ya sale en la línea de arriba).
    final file = [
      if (v.height != null) '${v.height}p',
      if (v.vcodec != null) v.vcodec!,
      v.sizeLabel,
    ].where((e) => e.isNotEmpty).join(' · ');
    return InkWell(
      focusColor: Colors.white12,
      borderRadius: radius > 0 ? BorderRadius.circular(radius) : null,
      onTap: onTap,
      onLongPress: onLong,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 136,
              height: 77,
              child: Stack(fit: StackFit.expand, children: [
                Image.network(
                    v.stillV > 0 ? api.stillUrl(v) : api.thumbUrl(v.id),
                    headers: api.authHeaders,
                    fit: BoxFit.cover,
                    cacheWidth: 272,
                    errorBuilder: (_, __, ___) => const ColoredBox(
                        color: Colors.black26,
                        child: Icon(Icons.play_circle_outline,
                            color: Colors.white38))),
                if (v.progress != null && !done)
                  Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                          value: v.progress,
                          minHeight: 3,
                          color: _red,
                          backgroundColor: Colors.black54)),
                if (done)
                  const Positioned(
                      top: 4,
                      right: 4,
                      child: Icon(Icons.check_circle,
                          size: 18, color: Color(0xFF46D369))),
                if (isNew && !done)
                  Positioned(
                      top: 4,
                      left: 4,
                      child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: _red,
                              borderRadius: BorderRadius.circular(4)),
                          child: const Text('NUEVO',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white)))),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    movie || v.episode == null
                        ? v.title
                        : '${v.episode}. ${v.epTitle ?? v.title}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14.5)),
                if (meta.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(meta.join(' · '),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12))),
                if (movie && file.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(file,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12))),
                if (overview != null && overview.isNotEmpty)
                  Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(overview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 12))),
              ])),
          if (trailing != null) trailing!,
        ]),
      ),
    );
  }
}
