import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared/audiobook.dart';
import 'api.dart';
import 'book_cache.dart';
import 'book_downloads.dart';
import 'book_playback.dart';
import 'core.dart';
import 'downloads.dart' show confirmAction;
import 'remote.dart' show serverOfflineProvider;
import 'tv.dart';

const _bg = Color(0xff141414), _accent = Color(0xffe50914);
final audioBooksProvider =
    FutureProvider.autoDispose<List<AudioBook>>((ref) async {
  final api = ref.watch(apiProvider);
  if (api == null) return [];
  await ref.watch(libraryProvider.future);
  return api.audioBooks();
});

String _profile(WidgetRef ref) =>
    ref.read(prefsProvider).getString('profile_username') ?? '';

/// Only consumes a notification link after the normal profile gate has opened.
class BookNotificationGate extends ConsumerStatefulWidget {
  const BookNotificationGate({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<BookNotificationGate> createState() =>
      _BookNotificationGateState();
}

class _BookNotificationGateState extends ConsumerState<BookNotificationGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    if (!Platform.isAndroid) return;
    WidgetsBinding.instance.addObserver(this);
    BookPlayback.channel.setMethodCallHandler((call) async {
      if (call.method == 'notificationTap') await _open();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _open();
  }

  Future<void> _open() async {
    if (!mounted) return;
    final raw = await BookPlayback.channel.invokeMethod<String>('takeLink');
    if (!mounted || raw == null) return;
    final data = jsonDecode(raw) as Map;
    final book = AudioBook.fromJson(data['book']);
    final api = ref.read(apiProvider);
    if (api == null || listeningKey(api, _profile(ref), book) != data['key'])
      return;
    final nav = Navigator.of(context);
    final target = 'audio/${book.id}';
    var same = false;
    nav.popUntil((route) {
      same = route.settings.name == target;
      return same || route.isFirst;
    });
    if (!same && mounted) openBook(context, api, book);
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      WidgetsBinding.instance.removeObserver(this);
      BookPlayback.channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

void openBook(BuildContext context, Api api, AudioBook book) =>
    Navigator.of(context).push(MaterialPageRoute(
        settings: RouteSettings(name: 'audio/${book.id}'),
        builder: (_) => _BookPage(api: api, book: book)));

Widget _badge() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
        color: const Color(0xda171719),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24, width: .7)),
    child: const Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.headphones_rounded, size: 13, color: Colors.white),
      SizedBox(width: 5),
      Text('Audiolibro',
          style: TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600))
    ]));

Widget _art(Api api, AudioBook book, BookCopy? copy, {bool wide = false}) {
  final useWide = wide && book.backdrop != null;
  final id = useWide ? book.backdrop : (book.poster ?? book.backdrop);
  const fallback = DecoratedBox(
      decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xff40252b), Color(0xff201f24)])),
      child: Center(
          child:
              Icon(Icons.headphones_rounded, size: 42, color: Colors.white38)));
  if (id == null) return fallback;
  final file = copy?.asset(id);
  if (file != null && file.existsSync())
    return Image.file(file,
        fit: BoxFit.cover,
        cacheWidth: wide ? 1280 : 300,
        errorBuilder: (_, __, ___) => fallback);
  return Image.network(
      api.bookArtUrl(book, id == book.poster ? 'poster' : 'backdrop'),
      headers: api.authHeaders,
      fit: BoxFit.cover,
      cacheWidth: wide ? 1280 : 300,
      errorBuilder: (_, __, ___) => fallback);
}

class AudioBookCard extends ConsumerWidget {
  const AudioBookCard(
      {super.key,
      required this.api,
      required this.book,
      this.width,
      this.focusNode});
  final Api api;
  final AudioBook book;
  final double? width;
  final FocusNode? focusNode;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final copy =
        ref.watch(bookDownloadsProvider.select((d) => d.readyFor(book.id)));
    final tv = ref.watch(tvModeProvider);
    void open() => openBook(context, api, book);
    final card = SizedBox(
        width: width,
        child: AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(fit: StackFit.expand, children: [
                  _art(api, book, copy),
                  const DecoratedBox(
                      decoration: BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              stops: [.48, 1],
                              colors: [Colors.transparent, Colors.black87]))),
                  Positioned(left: 7, top: 7, child: _badge()),
                  Positioned(
                      left: 10,
                      right: 10,
                      bottom: 10,
                      child: Text(book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              height: 1.12,
                              color: Colors.white))),
                  if (!tv)
                    Material(
                        color: Colors.transparent, child: InkWell(onTap: open))
                ]))));
    return tv
        ? TvFocusable(focusNode: focusNode, onTap: open, child: card)
        : card;
  }
}

String _time(int ms) {
  final s = Duration(milliseconds: ms);
  final sec = (s.inSeconds % 60).toString().padLeft(2, '0');
  return s.inHours == 0
      ? '${s.inMinutes}:$sec'
      : '${s.inHours}:${(s.inMinutes % 60).toString().padLeft(2, '0')}:$sec';
}

class _BookPage extends ConsumerStatefulWidget {
  const _BookPage({required this.api, required this.book});
  final Api api;
  final AudioBook book;
  @override
  ConsumerState<_BookPage> createState() => _BookPageState();
}

class _BookPageState extends ConsumerState<_BookPage>
    with WidgetsBindingObserver {
  AudioBook get book => widget.book;
  late final String _key;
  Timer? _timer;
  ListeningState state = const ListeningState();
  bool _busy = false, _reading = false, _loaded = false;
  double? _drag;
  String? _error;
  @override
  void initState() {
    super.initState();
    _key = listeningKey(widget.api, _profile(ref), book);
    WidgetsBinding.instance.addObserver(this);
    _watch();
  }

  void _watch() {
    _refresh();
    _timer?.cancel();
    _timer =
        Timer.periodic(const Duration(milliseconds: 700), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      _watch();
    } else {
      _timer?.cancel();
    }
  }

  Future<void> _refresh() async {
    if (_reading || !mounted) return;
    _reading = true;
    try {
      final s = await BookPlayback.status(_key);
      if (mounted &&
          (!_loaded ||
              s.track != state.track ||
              s.position ~/ 1000 != state.position ~/ 1000 ||
              s.duration != state.duration ||
              s.playing != state.playing ||
              s.active != state.active ||
              s.ended != state.ended ||
              s.local != state.local ||
              s.error != state.error)) {
        setState(() {
          state = s;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _loaded = true;
          _error = 'No se pudo consultar el reproductor.';
        });
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
      await _refresh();
    } catch (_) {
      if (mounted)
        setState(() =>
            _error = 'No se pudo reproducir la pista. Vuelve a intentarlo.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _play([int? i]) => _run(() async {
        final copy = ref.read(bookDownloadsProvider).readyFor(book.id);
        if (i == null && state.active && state.playing) {
          await BookPlayback.command(_key, 'pause');
          return;
        }
        final onDisk = copy != null &&
            book.tracks.every((t) => copy.asset(t.id).existsSync());
        if (state.active &&
            !state.ended &&
            state.error == null &&
            state.local == onDisk) {
          await BookPlayback.command(_key, i == null ? 'play' : 'jump', i ?? 0);
        } else {
          await BookPlayback.open(widget.api, book, _key, copy, index: i ?? -1);
        }
      });
  Future<void> _remove(BookDownloads dl) async {
    if (!await confirmAction(
        context,
        'Eliminar descarga',
        'Se quitarán los audios y las portadas de este dispositivo. Conservarás tu posición.',
        'Eliminar')) return;
    if (!mounted) return;
    await _run(() async {
      if (state.local) await BookPlayback.stop(_key);
      await dl.remove(book.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dl = ref.watch(bookDownloadsProvider), copy = dl.readyFor(book.id);
    final progress = dl.progress[book.id],
        offline = ref.watch(serverOfflineProvider);
    final index = book.tracks.indexWhere((t) => t.id == state.track);
    final hasMark = index >= 0 && !state.ended;
    final canPlay = _loaded && !_busy && (copy != null || !offline);
    final current = hasMark ? index : 0;
    final downloaded =
        copy != null && (copy.book.revision == book.revision || offline);
    final playing = state.active && state.playing;
    final cta = playing
        ? 'Pausar'
        : state.ended
            ? 'Volver a escuchar'
            : hasMark
                ? 'Reanudar'
                : 'Escuchar';
    final issue = _error ?? state.error ?? dl.errors[book.id];
    final w = MediaQuery.sizeOf(context).width;
    final pad = EdgeInsets.symmetric(
        horizontal: w > 900
            ? (w - 840) / 2
            : w >= 600
                ? 40
                : 20);
    return Scaffold(
        backgroundColor: _bg,
        body: CustomScrollView(slivers: [
          SliverAppBar(
              pinned: true,
              backgroundColor: _bg,
              foregroundColor: Colors.white,
              expandedHeight: w >= 700 ? 235 : 175,
              flexibleSpace: FlexibleSpaceBar(
                  background: Stack(fit: StackFit.expand, children: [
                _art(widget.api, book, copy, wide: true),
                const DecoratedBox(
                    decoration: BoxDecoration(
                        gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.black38, Colors.transparent, _bg],
                            stops: [0, .35, 1])))
              ]))),
          SliverPadding(
              padding: pad,
              sliver: SliverToBoxAdapter(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          ClipRRect(
                              borderRadius: BorderRadius.circular(9),
                              child: SizedBox(
                                  width: w >= 700 ? 92 : 73,
                                  height: w >= 700 ? 130 : 104,
                                  child: _art(widget.api, book, copy))),
                          const SizedBox(width: 16),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                _badge(),
                                const SizedBox(height: 8),
                                Text(book.title,
                                    style: TextStyle(
                                        fontSize: w >= 700 ? 32 : 24,
                                        fontWeight: FontWeight.w700,
                                        height: 1.1,
                                        letterSpacing: -.5,
                                        color: Colors.white)),
                                if (book.author.isNotEmpty)
                                  Padding(
                                      padding: const EdgeInsets.only(top: 5),
                                      child: Text(book.author,
                                          style: const TextStyle(
                                              color: Colors.white70))),
                                if (book.narrator.isNotEmpty)
                                  Text('Narración de ${book.narrator}',
                                      style: const TextStyle(
                                          color: Colors.white60))
                              ]))
                        ]),
                    const SizedBox(height: 20),
                    Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                              autofocus: true,
                              style: FilledButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 24, vertical: 13)),
                              onPressed: canPlay ? () => _play() : null,
                              icon: Icon(playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded),
                              label: Text(cta)),
                          OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side:
                                      const BorderSide(color: Colors.white38)),
                              onPressed: progress != null
                                  ? () => dl.pause(book.id)
                                  : downloaded
                                      ? () => _remove(dl)
                                      : offline
                                          ? null
                                          : () => dl.start(widget.api, book),
                              icon: Icon(progress != null
                                  ? Icons.pause_rounded
                                  : downloaded
                                      ? Icons.download_done_rounded
                                      : Icons.download_rounded),
                              label: Text(progress != null
                                  ? 'Pausar · ${(progress * 100).round()}%'
                                  : downloaded
                                      ? 'Descargado'
                                      : copy != null
                                          ? 'Actualizar descarga'
                                          : dl.copies.containsKey(book.id)
                                              ? 'Continuar descarga'
                                              : 'Descargar')),
                          if (!downloaded &&
                              dl.copies.containsKey(book.id) &&
                              progress == null)
                            IconButton(
                                tooltip: 'Eliminar descarga',
                                onPressed: () => _remove(dl),
                                icon: const Icon(Icons.delete_outline_rounded))
                        ]),
                    if (progress != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: LinearProgressIndicator(
                              value: progress, color: _accent)),
                    if (issue != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(issue,
                              style:
                                  const TextStyle(color: Color(0xffffacaa)))),
                    if (hasMark)
                      Container(
                          margin: const EdgeInsets.only(top: 16),
                          padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
                          decoration: BoxDecoration(
                              color: const Color(0xff212123),
                              borderRadius: BorderRadius.circular(12)),
                          child: Column(children: [
                            Row(children: [
                              const Icon(Icons.graphic_eq_rounded,
                                  color: _accent, size: 19),
                              const SizedBox(width: 9),
                              Expanded(
                                  child: Text(book.tracks[current].title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600))),
                              IconButton(
                                  tooltip: 'Pista anterior',
                                  onPressed: canPlay && current > 0
                                      ? () => _play(current - 1)
                                      : null,
                                  icon:
                                      const Icon(Icons.skip_previous_rounded)),
                              IconButton(
                                  tooltip: 'Pista siguiente',
                                  onPressed: canPlay &&
                                          current + 1 < book.tracks.length
                                      ? () => _play(current + 1)
                                      : null,
                                  icon: const Icon(Icons.skip_next_rounded))
                            ]),
                            Row(children: [
                              Text(_time((_drag ?? state.position.toDouble())
                                  .round())),
                              Expanded(
                                  child: Slider(
                                      activeColor: _accent,
                                      value:
                                          (_drag ?? state.position.toDouble())
                                              .clamp(
                                                  0.0,
                                                  state.duration
                                                      .clamp(1, 1 << 52)
                                                      .toDouble()),
                                      max: state.duration
                                          .clamp(1, 1 << 52)
                                          .toDouble(),
                                      onChanged:
                                          state.active && state.duration > 0
                                              ? (v) => setState(() => _drag = v)
                                              : null,
                                      onChangeEnd: (v) {
                                        setState(() => _drag = null);
                                        _run(() => BookPlayback.command(
                                            _key, 'seek', v.round()));
                                      })),
                              Text(_time(state.duration))
                            ])
                          ])),
                    if (book.description.isNotEmpty)
                      Padding(
                          padding: const EdgeInsets.only(top: 18),
                          child: Text(book.description,
                              style: const TextStyle(
                                  height: 1.45, color: Colors.white70))),
                    const SizedBox(height: 24),
                    Row(children: [
                      Container(width: 3, height: 17, color: _accent),
                      const SizedBox(width: 9),
                      const Expanded(
                          child: Text('Pistas',
                              style: TextStyle(
                                  fontSize: 19, fontWeight: FontWeight.bold))),
                      Text('${book.tracks.length}',
                          style: const TextStyle(color: Colors.white60))
                    ]),
                    const SizedBox(height: 8)
                  ]))),
          SliverPadding(
              padding: pad,
              sliver: SliverList.builder(
                  itemCount: book.tracks.length,
                  itemBuilder: (_, i) {
                    final selected = hasMark && i == index;
                    return ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9)),
                        tileColor: selected ? const Color(0xff252123) : null,
                        leading: SizedBox(
                            width: 30,
                            child: selected
                                ? const Icon(Icons.graphic_eq_rounded,
                                    color: _accent)
                                : Text((i + 1).toString().padLeft(2, '0'),
                                    style: const TextStyle(
                                        color: Colors.white54))),
                        title: Text(book.tracks[i].title),
                        trailing: const Icon(Icons.play_arrow_rounded,
                            size: 18, color: Colors.white54),
                        onTap: canPlay ? () => _play(i) : null);
                  })),
          const SliverSafeArea(
              top: false,
              sliver: SliverToBoxAdapter(child: SizedBox(height: 24)))
        ]));
  }
}

class DownloadedBooks extends ConsumerWidget {
  const DownloadedBooks({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dl = ref.watch(bookDownloadsProvider), api = ref.watch(apiProvider);
    if (dl.copies.isEmpty || api == null)
      return const Center(
          child: Text('Aquí aparecerán tus audiolibros descargados.'));
    return ListView(children: [
      for (final c in dl.copies.values)
        ListTile(
            leading: SizedBox(
                width: 38,
                height: 52,
                child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: _art(api, c.book, c))),
            title: Text(c.book.title),
            subtitle: Text(dl.progress.containsKey(c.book.id)
                ? 'Descargando · ${(100 * dl.progress[c.book.id]!).round()}%'
                : c.complete
                    ? 'Disponible sin conexión'
                    : 'Descarga pendiente'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openBook(context, api, c.book))
    ]);
  }
}
