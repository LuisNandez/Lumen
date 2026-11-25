import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:server_core/server_core.dart';

import 'audiobooks_page.dart';

enum _Filter { all, noPoster, movies, shows }

String _fmtSize(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(1)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(0)} MB';
  return '${(b / 1024).toStringAsFixed(0)} KB';
}

/// Biblioteca del servidor: rejilla de carátulas a la izquierda y, al elegir una,
/// un panel a la derecha para cambiarla (TMDB, imagen del PC o dirección web).
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.server,
    required this.selectedId,
    required this.onSelect,
  });
  final MediaServer? server;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _q = TextEditingController();
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  bool _passes(LibraryEntry e, String q) {
    switch (_filter) {
      case _Filter.noPoster:
        if (e.hasPoster) return false;
      case _Filter.movies:
        if (e.isShow) return false;
      case _Filter.shows:
        if (!e.isShow) return false;
      case _Filter.all:
        break;
    }
    if (q.isEmpty) return true;
    return e.title.toLowerCase().contains(q) ||
        e.fileName.toLowerCase().contains(q) ||
        e.guessTitle.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.server;
    if (s == null || !s.running) {
      return const _Empty(
          icon: Icons.power_settings_new,
          text: 'Inicia el servidor para ver tu biblioteca.');
    }
    final all = s.libraryEntries;
    final missing = all.where((e) => !e.hasPoster).length;
    final q = _q.text.trim().toLowerCase();
    final list = [
      for (final e in all)
        if (_passes(e, q)) e
    ];
    LibraryEntry? sel;
    for (final e in all) {
      if (e.id == widget.selectedId) sel = e;
    }

    final toolbar = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 260,
            child: TextField(
              controller: _q,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Buscar…',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _q.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(_q.clear)),
              ),
            ),
          ),
          SegmentedButton<_Filter>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(
                  value: _Filter.all, label: Text('Todo (${all.length})')),
              ButtonSegment(
                  value: _Filter.noPoster,
                  label: Text('Sin carátula ($missing)')),
              const ButtonSegment(value: _Filter.movies, label: Text('Películas')),
              const ButtonSegment(value: _Filter.shows, label: Text('Series')),
            ],
            selected: {_filter},
            onSelectionChanged: (v) => setState(() => _filter = v.first),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.headphones_rounded, size: 18),
            label: Text('Audiolibros (${s.audioBooks.books.length})'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => AudioBooksPage(store: s.audioBooks))),
          ),
          if (s.tmdbEnabled && missing > 0)
            FilledButton.tonalIcon(
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: const Text('Identificar automáticamente'),
              onPressed: () {
                s.autoScrapeAll();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'Buscando carátulas en segundo plano. Aparecerán solas.')));
              },
            ),
        ],
      ),
    );

    final grid = list.isEmpty
        ? const _Empty(
            icon: Icons.movie_filter_outlined,
            text: 'No hay nada que coincida con el filtro.')
        : GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 170,
                childAspectRatio: 2 / 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final e = list[i];
              final isSel = e.id == widget.selectedId;
              return _PosterCard(
                key: ValueKey(e.id),
                server: s,
                entry: e,
                selected: isSel,
                onTap: () => widget.onSelect(isSel ? null : e.id),
              );
            },
          );

    return Row(children: [
      Expanded(child: Column(children: [toolbar, Expanded(child: grid)])),
      if (sel != null) ...[
        const VerticalDivider(width: 1),
        SizedBox(
          width: 440,
          child: _PosterEditor(
            key: ValueKey(sel.id),
            server: s,
            entry: sel,
            onClose: () => widget.onSelect(null),
          ),
        ),
      ],
    ]);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: Colors.white38),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(color: Colors.white60)),
        ]),
      );
}

/// Imagen de un archivo del disco. Lee los bytes (no usa la caché por ruta de Flutter),
/// así que al cambiar [version] se ve la carátula nueva aunque el archivo se llame igual.
class _ArtImage extends StatefulWidget {
  const _ArtImage({
    super.key,
    required this.load,
    required this.version,
    this.cacheWidth = 340,
    this.fit = BoxFit.cover,
  });
  final Future<File?> Function() load;
  final Object version;
  final int cacheWidth;
  final BoxFit fit;

  @override
  State<_ArtImage> createState() => _ArtImageState();
}

class _ArtImageState extends State<_ArtImage> {
  late Future<Uint8List?> _bytes = _read();

  Future<Uint8List?> _read() async {
    try {
      final f = await widget.load();
      return f == null ? null : await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  void didUpdateWidget(_ArtImage old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _bytes = _read();
  }

  @override
  Widget build(BuildContext context) {
    const placeholder = ColoredBox(
        color: Colors.black26,
        child: Center(child: Icon(Icons.movie_outlined, size: 36, color: Colors.white24)));
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (_, snap) {
        final b = snap.data;
        if (b == null) return placeholder;
        return Image.memory(b,
            fit: widget.fit,
            cacheWidth: widget.cacheWidth,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => placeholder);
      },
    );
  }
}

/// Carátula de la película o serie; si no tiene, un fotograma del video con el aviso "Sin carátula".
Widget _artFor(MediaServer s, LibraryEntry e, {int cacheWidth = 340}) {
  if (e.hasPoster) {
    return _ArtImage(
        key: const ValueKey('poster'),
        version: e.posterV,
        cacheWidth: cacheWidth,
        load: () async => s.posterFile(e.id));
  }
  return Stack(fit: StackFit.expand, children: [
    _ArtImage(
        key: const ValueKey('thumb'),
        version: 0,
        cacheWidth: cacheWidth,
        load: () => s.thumbnailFile(e.id)),
    const ColoredBox(color: Color(0x88000000)),
  ]);
}

class _Chip extends StatelessWidget {
  const _Chip(this.text, this.color, {this.icon});
  final String text;
  final Color color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: Colors.black87),
            const SizedBox(width: 3),
          ],
          Text(text,
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87)),
        ]),
      );
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({
    super.key,
    required this.server,
    required this.entry,
    required this.selected,
    required this.onTap,
  });
  final MediaServer server;
  final LibraryEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final primary = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: e.fileName,
      waitDuration: const Duration(milliseconds: 600),
      child: Material(
        color: Colors.black26,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
                color: selected ? primary : Colors.transparent, width: 3)),
        child: InkWell(
          onTap: onTap,
          child: Stack(fit: StackFit.expand, children: [
            _artFor(server, e),
            Positioned(
              left: 6,
              top: 6,
              right: 6,
              child: Row(children: [
                if (!e.hasPoster) const _Chip('Sin carátula', Colors.amberAccent),
                const Spacer(),
                if (e.isShow) const _Chip('Serie', Colors.white70, icon: Icons.tv),
              ]),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 18, 8, 8),
                decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xDD000000)])),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(e.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w600)),
                      if (e.year != null)
                        Text('${e.year}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.white70)),
                    ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Diálogo para pegar la dirección de una imagen.
class _UrlDialog extends StatefulWidget {
  const _UrlDialog({this.title = 'Carátula desde una dirección web'});
  final String title;
  @override
  State<_UrlDialog> createState() => _UrlDialogState();
}

class _UrlDialogState extends State<_UrlDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: _c,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Dirección de la imagen (https://…)'),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _c.text),
              child: const Text('Descargar')),
        ],
      );
}

/// Formulario para escribir a mano la ficha de una película o serie.
class _InfoDialog extends StatefulWidget {
  const _InfoDialog(
      {required this.title, required this.isShow, required this.profile});
  final String title;
  final bool isShow;
  final Map<String, dynamic> profile;
  @override
  State<_InfoDialog> createState() => _InfoDialogState();
}

class _InfoDialogState extends State<_InfoDialog> {
  static String _txt(Object? v) => v == null ? '' : '$v';
  static String _list(Object? v) => v is List ? v.join(', ') : _txt(v);

  late final Map<String, TextEditingController> _c = {
    'title': TextEditingController(text: _txt(widget.profile['title'] ?? widget.title)),
    'originalTitle': TextEditingController(text: _txt(widget.profile['originalTitle'])),
    'year': TextEditingController(text: _txt(widget.profile['year'])),
    'runtime': TextEditingController(text: _txt(widget.profile['runtime'])),
    'rating': TextEditingController(text: _txt(widget.profile['rating'])),
    'certification': TextEditingController(text: _txt(widget.profile['certification'])),
    'tagline': TextEditingController(text: _txt(widget.profile['tagline'])),
    'genres': TextEditingController(text: _list(widget.profile['genres'])),
    'directors': TextEditingController(text: _list(widget.profile['directors'])),
    'cast': TextEditingController(text: _list(widget.profile['cast'])),
    'overview': TextEditingController(text: _txt(widget.profile['overview'])),
  };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _f(String key, String label,
          {int maxLines = 1, String? helper, TextInputType? type}) =>
      TextField(
        controller: _c[key],
        maxLines: maxLines,
        keyboardType: type,
        decoration: InputDecoration(
            isDense: true,
            labelText: label,
            helperText: helper,
            border: const OutlineInputBorder()),
      );

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 12);
    const decimal = TextInputType.numberWithOptions(decimal: true);
    return AlertDialog(
      title: Text('Ficha de "${widget.title}"'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 4),
            _f('title', 'Título'),
            gap,
            _f('originalTitle', 'Título original'),
            gap,
            Row(children: [
              Expanded(child: _f('year', 'Año', type: TextInputType.number)),
              const SizedBox(width: 10),
              Expanded(
                  child: _f('runtime', widget.isShow ? 'Min. por capítulo' : 'Minutos',
                      type: TextInputType.number)),
              const SizedBox(width: 10),
              Expanded(child: _f('rating', 'Valoración (0-10)', type: decimal)),
            ]),
            gap,
            _f('certification', 'Clasificación de edades',
                helper: 'Ej.: A, B, B15, C, PG-13, R, TV-MA, 12, 16'),
            gap,
            _f('tagline', 'Lema'),
            gap,
            _f('genres', 'Géneros', helper: 'Separados por comas'),
            gap,
            _f('directors', widget.isShow ? 'Creadores' : 'Dirección',
                helper: 'Separados por comas'),
            gap,
            _f('cast', 'Reparto', helper: 'Separados por comas'),
            gap,
            _f('overview', 'Sinopsis', maxLines: 6),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(context, {
                  for (final k in _c.keys) k: _c[k]!.text,
                }),
            child: const Text('Guardar')),
      ],
    );
  }
}

/// Lista de capítulos de una serie para cambiarles el nombre.
class _EpisodesDialog extends StatefulWidget {
  const _EpisodesDialog({required this.title, required this.rows});
  final String title;
  final List<EpisodeRow> rows;
  @override
  State<_EpisodesDialog> createState() => _EpisodesDialogState();
}

class _EpisodesDialogState extends State<_EpisodesDialog> {
  late final Map<String, TextEditingController> _c = {
    for (final r in widget.rows) r.id: TextEditingController(text: r.title),
  };

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Solo los capítulos cuyo nombre cambió (vacío = volver al nombre original).
  Map<String, String> _changes() => {
        for (final r in widget.rows)
          if (_c[r.id]!.text.trim() != r.title) r.id: _c[r.id]!.text.trim(),
      };

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    return AlertDialog(
      title: Text('Capítulos de "${widget.title}"'),
      content: SizedBox(
        width: 620,
        height: 460,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
              'Escribe el nombre nuevo de cada capítulo. Si dejas uno vacío, vuelve al nombre original.',
              style: TextStyle(fontSize: 12, color: Colors.white60)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (_, i) {
                final r = rows[i];
                final newSeason = i == 0 || rows[i - 1].season != r.season;
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (newSeason)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(0, 10, 0, 6),
                          child: Text(
                              r.season == 0 ? 'Especiales' : 'Temporada ${r.season}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          SizedBox(
                              width: 44,
                              child: Text(
                                  r.season == 0
                                      ? 'E${r.episode}'
                                      : 'E${r.episode.toString().padLeft(2, '0')}',
                                  style: const TextStyle(color: Colors.white60))),
                          Expanded(
                            child: TextField(
                              controller: _c[r.id],
                              decoration: InputDecoration(
                                  isDense: true,
                                  border: const OutlineInputBorder(),
                                  hintText: r.fileName,
                                  suffixIcon: r.manual
                                      ? const Tooltip(
                                          message: 'Nombre puesto a mano',
                                          child: Icon(Icons.edit, size: 16))
                                      : null),
                            ),
                          ),
                        ]),
                      ),
                    ]);
              },
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _changes()),
            child: const Text('Guardar')),
      ],
    );
  }
}

/// Panel lateral para asignar la carátula de una película o serie.
class _PosterEditor extends StatefulWidget {
  const _PosterEditor({
    super.key,
    required this.server,
    required this.entry,
    required this.onClose,
  });
  final MediaServer server;
  final LibraryEntry entry;
  final VoidCallback onClose;

  @override
  State<_PosterEditor> createState() => _PosterEditorState();
}

class _PosterEditorState extends State<_PosterEditor> {
  late final _q = TextEditingController(text: widget.entry.guessTitle);
  late final _year =
      TextEditingController(text: widget.entry.guessYear?.toString() ?? '');
  List<Map<String, dynamic>>? _results;
  bool _searching = false, _busy = false;
  String? _searchError;

  MediaServer get _s => widget.server;
  LibraryEntry get _e => widget.entry;

  @override
  void initState() {
    super.initState();
    if (_s.tmdbEnabled && (!_e.hasPoster || !_e.matched)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  @override
  void dispose() {
    _q.dispose();
    _year.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final r = await _s.searchTmdb(q,
          year: int.tryParse(_year.text.trim()),
          type: _e.isShow ? 'tv' : 'movie');
      if (mounted) setState(() => _results = r);
    } catch (err) {
      if (mounted) {
        setState(() {
          _results = null;
          _searchError =
              err is StateError ? err.message : 'No se pudo consultar TMDB: $err';
        });
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Ejecuta una acción del servidor mostrando el progreso y el resultado en un aviso.
  Future<void> _run(Future<String> Function() op) async {
    setState(() => _busy = true);
    String msg;
    try {
      msg = await op();
    } catch (err) {
      msg = err is StateError ? err.message : 'No se pudo completar: $err';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _apply(Map<String, dynamic> r) => _run(() async {
        await _s.applyTmdb(_e.id, r['id'] as int, '${r['type']}');
        return 'Carátula aplicada: ${r['title']}';
      });

  Future<void> _auto() => _run(() async {
        final ok = await _s.autoMatchEntry(_e.id);
        return ok
            ? 'Identificada y carátula descargada.'
            : 'No hubo una coincidencia clara. Elige una de la lista.';
      });

  Future<void> _pickImage() async {
    final pick = await FilePicker.platform.pickFiles(
        dialogTitle: 'Carátula de "${_e.title}"',
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp']);
    final path = pick?.files.single.path;
    if (path == null || !mounted) return;
    await _run(() async {
      await _s.setPosterFromFile(_e.id, path);
      return 'Carátula actualizada.';
    });
  }

  Future<void> _fromUrl() async {
    final url = await showDialog<String>(
        context: context, builder: (_) => const _UrlDialog());
    if (url == null || url.trim().isEmpty || !mounted) return;
    await _run(() async {
      await _s.setPosterFromUrl(_e.id, url.trim());
      return 'Carátula actualizada.';
    });
  }

  Future<void> _pickBackdrop() async {
    final pick = await FilePicker.platform.pickFiles(
        dialogTitle: 'Fondo horizontal de "${_e.title}"',
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp']);
    final path = pick?.files.single.path;
    if (path == null || !mounted) return;
    await _run(() async {
      await _s.setBackdropFromFile(_e.id, path);
      return 'Fondo actualizado.';
    });
  }

  Future<void> _backdropFromUrl() async {
    final url = await showDialog<String>(
        context: context,
        builder: (_) =>
            const _UrlDialog(title: 'Fondo desde una dirección web'));
    if (url == null || url.trim().isEmpty || !mounted) return;
    await _run(() async {
      await _s.setBackdropFromUrl(_e.id, url.trim());
      return 'Fondo actualizado.';
    });
  }

  Future<void> _editInfo() async {
    final fields = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => _InfoDialog(
            title: _e.title,
            isShow: _e.isShow,
            profile: _s.entryProfile(_e.id)));
    if (fields == null || !mounted) return;
    await _run(() async {
      await _s.updateEntryInfo(_e.id, fields);
      return 'Ficha guardada.';
    });
  }

  Future<void> _editEpisodes() async {
    final rows = _s.episodeRows(_e.id);
    if (rows.isEmpty) return;
    final names = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => _EpisodesDialog(title: _e.title, rows: rows));
    if (names == null || names.isEmpty || !mounted) return;
    await _run(() async {
      final n = await _s.renameEpisodes(names);
      return n == 1 ? 'Se cambió el nombre de 1 capítulo.' : 'Se cambió el nombre de $n capítulos.';
    });
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Restablecer "${_e.title}"'),
        content: const Text(
            'Se borran la ficha y las imágenes. Volverá a mostrarse con el nombre del archivo.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restablecer')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      _s.resetEntry(_e.id);
      return 'Restablecida.';
    });
  }

  Widget _resultsView() {
    if (!_s.tmdbEnabled) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
            'Para buscar carátulas en TMDB escribe tu clave en Ajustes. '
            'Mientras tanto puedes usar una imagen de tu PC o una dirección web.',
            style: TextStyle(color: Colors.white60)),
      );
    }
    if (_searching) return const Center(child: CircularProgressIndicator());
    if (_searchError != null) {
      return Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_searchError!,
              style: const TextStyle(color: Colors.redAccent)));
    }
    final r = _results;
    if (r == null) {
      return const Center(
          child: Text('Escribe un título y pulsa Enter.',
              style: TextStyle(color: Colors.white60)));
    }
    if (r.isEmpty) {
      return const Center(
          child: Text('Sin resultados. Prueba otro título o quita el año.',
              style: TextStyle(color: Colors.white60)));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: r.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final m = r[i];
        final url = m['posterUrl'] as String?;
        final year = m['year'];
        final overview = '${m['overview'] ?? ''}'.trim();
        const noPoster = ColoredBox(
            color: Colors.black26, child: Icon(Icons.movie_outlined));
        return ListTile(
          enabled: !_busy,
          onTap: () => _apply(m),
          leading: SizedBox(
            width: 46,
            height: 69,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: url == null
                  ? noPoster
                  : Image.network(url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => noPoster),
            ),
          ),
          title: Text('${m['title']}${year == null ? '' : ' ($year)'}',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(overview.isEmpty ? 'Sin sinopsis' : overview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
          trailing: const Tooltip(
              message: 'Usar esta carátula',
              child: Icon(Icons.download_outlined)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = _e;
    const dim = TextStyle(fontSize: 12, color: Colors.white60);
    const compact = VisualDensity.compact;
    return Container(
      color: const Color(0x08FFFFFF),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(children: [
            Expanded(
                child: Text(e.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600))),
            IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cerrar',
                onPressed: widget.onClose),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 130,
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _artFor(_s, e, cacheWidth: 400)),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        e.isShow
                            ? 'Serie · ${e.episodes} capítulos'
                            : 'Película',
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                        [
                          if (e.year != null) '${e.year}',
                          if (e.rating != null) '★ ${e.rating}',
                          _fmtSize(e.sizeBytes),
                        ].join(' · '),
                        style: dim),
                    const SizedBox(height: 2),
                    Text(e.fileName,
                        maxLines: 2, overflow: TextOverflow.ellipsis, style: dim),
                    const SizedBox(height: 6),
                    Text(
                        e.hasPoster
                            ? (e.matched
                                ? 'Con ficha de TMDB'
                                : 'Carátula propia')
                            : (e.overview != null
                                ? 'Ficha manual · sin carátula'
                                : 'Sin carátula'),
                        style: TextStyle(
                            fontSize: 12,
                            color: e.hasPoster
                                ? Colors.greenAccent
                                : Colors.amberAccent)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(visualDensity: compact),
                          onPressed: _busy ? null : _pickImage,
                          icon: const Icon(Icons.image_outlined, size: 18),
                          label: const Text('Imagen del PC…')),
                      OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(visualDensity: compact),
                          onPressed: _busy ? null : _fromUrl,
                          icon: const Icon(Icons.link, size: 18),
                          label: const Text('Desde URL…')),
                      if (_s.tmdbEnabled)
                        OutlinedButton.icon(
                            style:
                                OutlinedButton.styleFrom(visualDensity: compact),
                            onPressed: _busy ? null : _auto,
                            icon: const Icon(Icons.auto_fix_high, size: 18),
                            label: const Text('Identificar solo')),
                      OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(visualDensity: compact),
                          onPressed: _busy ? null : _editInfo,
                          icon: const Icon(Icons.edit_note, size: 18),
                          label: const Text('Editar ficha…')),
                      if (e.isShow)
                        OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(visualDensity: compact),
                            onPressed: _busy ? null : _editEpisodes,
                            icon: const Icon(Icons.format_list_numbered, size: 18),
                            label: const Text('Capítulos…')),
                      if (e.hasPoster || e.hasBackdrop || e.matched)
                        TextButton.icon(
                            style: TextButton.styleFrom(visualDensity: compact),
                            onPressed: _busy ? null : _reset,
                            icon: const Icon(Icons.restart_alt, size: 18),
                            label: const Text('Restablecer')),
                    ]),
                  ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 230,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: e.hasBackdrop
                      ? _ArtImage(
                          key: const ValueKey('backdrop'),
                          version: e.backdropV,
                          cacheWidth: 800,
                          load: () async => _s.backdropFile(e.id))
                      : const ColoredBox(
                          color: Colors.black26,
                          child: Center(
                              child: Icon(Icons.panorama_outlined,
                                  size: 32, color: Colors.white24))),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Fondo horizontal',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    const Text('La imagen de arriba al entrar a la película.',
                        style: dim),
                    const SizedBox(height: 6),
                    Text(e.hasBackdrop ? 'Con fondo' : 'Sin fondo',
                        style: TextStyle(
                            fontSize: 12,
                            color: e.hasBackdrop
                                ? Colors.greenAccent
                                : Colors.amberAccent)),
                    const SizedBox(height: 10),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(visualDensity: compact),
                          onPressed: _busy ? null : _pickBackdrop,
                          icon: const Icon(Icons.panorama_outlined, size: 18),
                          label: const Text('Fondo del PC…')),
                      OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(visualDensity: compact),
                          onPressed: _busy ? null : _backdropFromUrl,
                          icon: const Icon(Icons.link, size: 18),
                          label: const Text('Fondo desde URL…')),
                    ]),
                  ]),
            ),
          ]),
        ),
        SizedBox(
            height: 3,
            child: _busy ? const LinearProgressIndicator() : null),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _q,
                enabled: _s.tmdbEnabled,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Buscar en TMDB',
                    border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 80,
              child: TextField(
                controller: _year,
                enabled: _s.tmdbEnabled,
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _search(),
                decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Año',
                    border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
                tooltip: 'Buscar',
                onPressed: _s.tmdbEnabled && !_searching ? _search : null,
                icon: const Icon(Icons.search)),
          ]),
        ),
        Expanded(child: _resultsView()),
      ]),
    );
  }
}
