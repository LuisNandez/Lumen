import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/shared.dart';

import 'api.dart';
import 'core.dart';
import 'notifications.dart';
import 'peticiones.dart' show PeticionesScreen;
import 'remote.dart' show serverOfflineProvider;
import 'sounds.dart';
import 'theater.dart' show ShowScreen, playVideo;
import 'tv.dart' show tvModeProvider;

// ===========================================================================
//  Novedades: capítulos nuevos de series que ya tenías en la biblioteca.
//  Campanita con contador en la barra + pantalla "Novedades" (una entrada por
//  serie, como Netflix). El servidor decide qué es nuevo; ver /api/news.
// ===========================================================================

const _bg = Color(0xFF141414);
const _red = Color(0xFFE50914);

/// Campanita para las barras superiores. Muestra cuántas novedades están sin abrir.
class NewsBell extends ConsumerWidget {
  const NewsBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(apiProvider) == null || ref.watch(serverOfflineProvider)) {
      return const SizedBox.shrink();
    }
    final unread = (ref.watch(newsProvider).valueOrNull?.unread ?? 0) +
        ref.watch(inboxUnreadProvider);
    final tv = ref.watch(tvModeProvider);
    return IconButton(
      tooltip: unread > 0 ? 'Novedades ($unread sin abrir)' : 'Novedades',
      // TV: círculo de 46 px con fondo oscuro translúcido, a juego con el botón de buscar (el aro
      // de foco del tema lo sigue exacto). Móvil: un poco más estrecha para no apretar la barra.
      style: tv
          ? IconButton.styleFrom(
              backgroundColor: const Color(0x59000000),
              fixedSize: const Size(46, 46))
          : null,
      constraints: tv ? null : const BoxConstraints(minWidth: 40, minHeight: 48),
      padding: tv ? null : const EdgeInsets.symmetric(horizontal: 8),
      icon: Badge(
        isLabelVisible: unread > 0,
        backgroundColor: _red,
        textColor: Colors.white,
        label: Text(unread > 9 ? '9+' : '$unread'),
        child:
            Icon(unread > 0 ? Icons.notifications : Icons.notifications_none),
      ),
      onPressed: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => const NewsScreen())),
    );
  }
}

/// "hace 5 min", "hace 3 h", "hace 2 días"...
String _ago(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'ahora';
  if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
  if (d.inHours < 24) return 'hace ${d.inHours} h';
  if (d.inDays < 30) {
    return 'hace ${d.inDays} ${d.inDays == 1 ? 'día' : 'días'}';
  }
  final m = d.inDays ~/ 30;
  return 'hace $m ${m == 1 ? 'mes' : 'meses'}';
}

/// "T2 · E5–E7" (misma temporada) o "T1 · E9 – T2 · E2".
String _range(List<NewsEpisode> eps) {
  final a = eps.first, b = eps.last;
  if (a.season == b.season) {
    return a.season == 0
        ? 'Especiales'
        : 'T${a.season} · E${a.episode}–E${b.episode}';
  }
  return '${a.label} – ${b.label}';
}

class NewsScreen extends ConsumerWidget {
  const NewsScreen({super.key});

  Future<void> _readAll(BuildContext context, WidgetRef ref, Api api) async {
    await api.markNewsRead();
    ref.invalidate(newsProvider);
  }

  /// Reproduce el primer capítulo nuevo que aún no has visto.
  Future<void> _play(
      BuildContext context, WidgetRef ref, Api api, NewsItem n) async {
    final ep = n.firstPending ?? n.episodes.first;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await api.markNewsRead(showId: n.showId);
      ref.invalidate(newsProvider);
      final d = await api.detail(ep.id);
      if (!context.mounted) return;
      await playVideo(context, api, d.item);
    } catch (e) {
      messenger.showSnackBar(errorSnack(errText(e)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    if (api == null) return const SizedBox();
    final news = ref.watch(newsProvider);
    final data = news.valueOrNull;
    final inbox = ref.watch(inboxProvider);

    Widget body;
    if (data == null) {
      body = const Center(child: CircularProgressIndicator(color: _red));
    } else if (data.items.isEmpty && inbox.isEmpty) {
      body = RefreshIndicator(
        onRefresh: () async {
          await ref.refresh(newsProvider.future);
        },
        child: ListView(children: const [
          SizedBox(height: 120),
          Icon(Icons.notifications_none, size: 56, color: Colors.white24),
          SizedBox(height: 16),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'No hay capítulos nuevos.\n\n'
              'Aquí aparecen los capítulos que se añaden a las series que ya tienes '
              'y que aún no has visto.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, height: 1.4),
            ),
          ),
        ]),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: () async {
          await ref.refresh(newsProvider.future);
        },
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: inbox.length + data.items.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, color: Colors.white10),
          itemBuilder: (ctx, i) {
            if (i < inbox.length) {
              final it = inbox[i];
              return Dismissible(
                key: ValueKey('inbox:${it.key}'),
                background: const ColoredBox(color: Colors.black26),
                onDismissed: (_) =>
                    ref.read(inboxProvider.notifier).remove(it.key),
                child: _InboxTile(
                  item: it,
                  onOpen: () {
                    ref.read(inboxProvider.notifier).markRead(it.key);
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const PeticionesScreen()));
                  },
                ),
              );
            }
            final n = data.items[i - inbox.length];
            return _NewsTile(
              api: api,
              item: n,
              // Abrir la serie la marca como leída (lo hace su ficha).
              onOpen: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ShowScreen(showId: n.showId))),
              onPlay: () => _play(context, ref, api, n),
            );
          },
        ),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text('Novedades'),
        actions: [
          if ((data?.unread ?? 0) > 0 || ref.watch(inboxUnreadProvider) > 0)
            IconButton(
                icon: const Icon(Icons.done_all),
                tooltip: 'Marcar todo como leído',
                onPressed: () {
                  Sfx.play(Snd.marcarVisto, force: true);
                  ref.read(inboxProvider.notifier).markAllRead();
                  _readAll(context, ref, api);
                }),
        ],
      ),
      body: body,
    );
  }
}

/// Aviso de una petición tuya que ya está disponible en la biblioteca.
class _InboxTile extends StatelessWidget {
  const _InboxTile({required this.item, required this.onOpen});
  final InboxItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final what = item.type == 'tv' ? 'Tu serie pedida' : 'Tu película pedida';
    final poster = item.posterUrl;
    return InkWell(
      focusColor: Colors.white12,
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 52,
              height: 77,
              child: poster == null
                  ? const ColoredBox(
                      color: Colors.black26,
                      child: Icon(Icons.movie_outlined, color: Colors.white38))
                  : Image.network(poster,
                      fit: BoxFit.cover,
                      cacheWidth: 104,
                      errorBuilder: (_, __, ___) => const ColoredBox(
                          color: Colors.black26,
                          child:
                              Icon(Icons.movie_outlined, color: Colors.white38))),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ya está disponible',
                      style: TextStyle(
                          color: Colors.greenAccent.shade200,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(item.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight:
                              item.read ? FontWeight.w500 : FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('$what · ${_ago(item.ms)}',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
          ),
          if (!item.read)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.circle, size: 10, color: _red),
            ),
        ]),
      ),
    );
  }
}

class _NewsTile extends StatelessWidget {
  const _NewsTile(
      {required this.api,
      required this.item,
      required this.onOpen,
      required this.onPlay});
  final Api api;
  final NewsItem item;
  final VoidCallback onOpen, onPlay;

  @override
  Widget build(BuildContext context) {
    // Los que ya viste no salen del servidor, pero por si acaso se cae a la lista completa.
    final eps = item.pending.isEmpty ? item.episodes : item.pending;
    final first = eps.first;
    final single = eps.length == 1;
    final what = single
        ? 'Nuevo capítulo · ${first.label}'
        : '${eps.length} capítulos nuevos · ${_range(eps)}';
    final epTitle = single ? first.title : null;
    final still = first.stillV > 0
        ? api.stillUrl(VideoItem(first.id, '', 0, stillV: first.stillV))
        : api.thumbUrl(first.id);

    return InkWell(
      focusColor: Colors.white12,
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 136,
              height: 77,
              child: Stack(fit: StackFit.expand, children: [
                Image.network(still,
                    headers: api.authHeaders,
                    fit: BoxFit.cover,
                    cacheWidth: 272,
                    errorBuilder: (_, __, ___) => const ColoredBox(
                        color: Colors.black26,
                        child: Icon(Icons.tv, color: Colors.white38))),
                if (item.unread)
                  const Positioned(
                      top: 6,
                      left: 6,
                      child: CircleAvatar(radius: 5, backgroundColor: _red)),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.show,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight:
                              item.unread ? FontWeight.w800 : FontWeight.w600,
                          color: item.unread ? Colors.white : Colors.white70)),
                  const SizedBox(height: 2),
                  Text(what,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, color: Colors.white70)),
                  if (epTitle != null && epTitle.isNotEmpty)
                    Text(epTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white54)),
                  const SizedBox(height: 2),
                  Text(_ago(item.latestMs),
                      style: TextStyle(
                          fontSize: 12,
                          color: item.unread
                              ? const Color(0xFF6CA6FF)
                              : Colors.white38)),
                ]),
          ),
          IconButton(
              icon: const Icon(Icons.play_circle_outline),
              iconSize: 30,
              tooltip: single ? 'Reproducir' : 'Reproducir ${first.label}',
              onPressed: onPlay),
        ]),
      ),
    );
  }
}
