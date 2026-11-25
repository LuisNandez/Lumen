import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:server_core/server_core.dart';

class AudioBooksPage extends StatefulWidget {
  const AudioBooksPage({super.key, required this.store});
  final AudioBookStore store;
  @override
  State<AudioBooksPage> createState() => _AudioBooksPageState();
}

class _AudioBooksPageState extends State<AudioBooksPage> {
  Future<void> _edit([AudioBook? book]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => _Editor(store: widget.store, book: book)));
    if (mounted && saved == true) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final books = widget.store.books;
    return Scaffold(
        appBar: AppBar(title: const Text('Audiolibros')),
        body: Padding(
            padding: const EdgeInsets.all(20),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FilledButton.icon(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Añadir audiolibro')),
              const SizedBox(height: 16),
              Expanded(
                  child: books.isEmpty
                      ? const Center(child: Text('Todavía no hay audiolibros.'))
                      : ListView.separated(
                          itemCount: books.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final b = books[i];
                            return ListTile(
                                leading: SizedBox(
                                    width: 42,
                                    height: 58,
                                    child: b.poster == null
                                        ? const Icon(Icons.headphones_rounded)
                                        : Image.file(
                                            File(widget.store
                                                .assetPath(b, b.poster!)),
                                            fit: BoxFit.cover,
                                            cacheWidth: 120,
                                            errorBuilder: (_, __, ___) =>
                                                const Icon(
                                                    Icons.headphones_rounded))),
                                title: Text(b.title),
                                subtitle: Text([
                                  if (b.author.isNotEmpty) b.author,
                                  '${b.tracks.length} ${b.tracks.length == 1 ? "pista" : "pistas"}'
                                ].join(' · ')),
                                trailing: const Icon(Icons.edit_outlined),
                                onTap: () => _edit(b));
                          }))
            ])));
  }
}

class _DraftTrack {
  _DraftTrack(this.path, this.title);
  final String path;
  String title;
}

class _Editor extends StatefulWidget {
  const _Editor({required this.store, this.book});
  final AudioBookStore store;
  final AudioBook? book;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final _form = GlobalKey<FormState>();
  late String _title, _author, _narrator, _description;
  String? _poster, _backdrop, _error;
  final _tracks = <_DraftTrack>[];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final b = widget.book;
    _title = b?.title ?? '';
    _author = b?.author ?? '';
    _narrator = b?.narrator ?? '';
    _description = b?.description ?? '';
    if (b != null) {
      if (b.poster != null) _poster = widget.store.assetPath(b, b.poster!);
      if (b.backdrop != null)
        _backdrop = widget.store.assetPath(b, b.backdrop!);
      for (final t in b.tracks) {
        _tracks.add(_DraftTrack(widget.store.assetPath(b, t.id), t.title));
      }
    }
  }

  // Compara bloques numéricos por su valor: "2" va antes de "10".
  int _compareNames(PlatformFile a, PlatformFile b) {
    final opening = RegExp(
        r'^(?:[\d\s._-]+)?(?:intro(?:ducci[oó]n|duction)?|pr[oó]logo|prologue|prefacio|preface)(?:[\s._-]|$)',
        caseSensitive: false);
    final aOpening = opening.hasMatch(p.basenameWithoutExtension(a.name));
    final bOpening = opening.hasMatch(p.basenameWithoutExtension(b.name));
    if (aOpening != bOpening) return aOpening ? -1 : 1;
    final re = RegExp(r'\d+|\D+');
    final aa = re.allMatches(a.name.toLowerCase()).map((m) => m[0]!).toList();
    final bb = re.allMatches(b.name.toLowerCase()).map((m) => m[0]!).toList();
    for (var i = 0; i < aa.length && i < bb.length; i++) {
      final na = BigInt.tryParse(aa[i]), nb = BigInt.tryParse(bb[i]);
      final c =
          na != null && nb != null ? na.compareTo(nb) : aa[i].compareTo(bb[i]);
      if (c != 0) return c;
    }
    final c = aa.length.compareTo(bb.length);
    return c != 0 ? c : a.name.compareTo(b.name);
  }

  Future<void> _pick({bool? horizontal}) async {
    try {
      final audio = horizontal == null;
      final picked = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowMultiple: audio,
          allowedExtensions:
              (audio ? audioTypes : bookImageTypes).keys.toList());
      if (!mounted || picked == null) return;
      final files = picked.files.where((f) => f.path != null).toList()
        ..sort(_compareNames);
      if (files.isEmpty) return;
      setState(() {
        _error = null;
        if (audio) {
          for (final f in files) {
            if (!_tracks.any((t) => p.equals(t.path, f.path!)))
              _tracks.add(
                  _DraftTrack(f.path!, p.basenameWithoutExtension(f.name)));
          }
        } else if (horizontal == true) {
          _backdrop = files.first.path;
        } else {
          _poster = files.first.path;
        }
      });
    } catch (e) {
      if (mounted)
        setState(() => _error = 'No se pudieron abrir los archivos: $e');
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_tracks.isEmpty || _tracks.any((t) => t.title.trim().isEmpty)) {
      setState(() =>
          _error = 'Añade al menos un audio y ponle un nombre a cada pista.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.save(
          previous: widget.book,
          title: _title,
          author: _author,
          narrator: _narrator,
          description: _description,
          posterPath: _poster,
          backdropPath: _backdrop,
          tracks: [for (final t in _tracks) (title: t.title, path: t.path)]);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted)
        setState(() {
          _error = 'No se pudo guardar: $e';
          _saving = false;
        });
    }
  }

  Widget _field(String label, String value, ValueChanged<String> change,
          {int lines = 1, bool required = false}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
              initialValue: value,
              maxLines: lines,
              onChanged: change,
              decoration: InputDecoration(
                  labelText: label, border: const OutlineInputBorder()),
              validator: (v) => required && (v ?? '').trim().isEmpty
                  ? 'Escribe el título'
                  : null));

  Widget _cover(bool horizontal) {
    final path = horizontal ? _backdrop : _poster;
    final label = horizontal ? 'Portada horizontal' : 'Portada principal';
    return SizedBox(
        width: horizontal ? 232 : 148,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label),
          const SizedBox(height: 6),
          SizedBox(
              height: 126,
              width: double.infinity,
              child: Material(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                      onTap: () => _pick(horizontal: horizontal),
                      child: path == null
                          ? const Icon(Icons.add_photo_alternate_outlined)
                          : Image.file(File(path),
                              fit: BoxFit.contain,
                              cacheWidth: 460,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.broken_image_outlined))))),
          if (path != null)
            TextButton(
                onPressed: () => setState(() {
                      if (horizontal) {
                        _backdrop = null;
                      } else {
                        _poster = null;
                      }
                    }),
                child: const Text('Quitar'))
        ]));
  }

  void _move(int from, int to) => setState(() {
        _tracks.insert(to, _tracks.removeAt(from));
      });

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_saving,
      child: Scaffold(
          appBar: AppBar(
              title: Text(widget.book == null
                  ? 'Añadir audiolibro'
                  : 'Editar audiolibro')),
          body: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: Column(children: [
                    Expanded(
                        child: AbsorbPointer(
                            absorbing: _saving,
                            child: Form(
                                key: _form,
                                child: ListView.builder(
                                    padding: const EdgeInsets.all(20),
                                    itemCount: 1 + _tracks.length,
                                    itemBuilder: (_, i) {
                                      if (i == 0)
                                        return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              _field('Título', _title,
                                                  (s) => _title = s,
                                                  required: true),
                                              _field('Autoría', _author,
                                                  (s) => _author = s),
                                              _field('Narración', _narrator,
                                                  (s) => _narrator = s),
                                              _field(
                                                  'Descripción',
                                                  _description,
                                                  (s) => _description = s,
                                                  lines: 3),
                                              Wrap(
                                                  spacing: 16,
                                                  runSpacing: 12,
                                                  children: [
                                                    _cover(false),
                                                    _cover(true)
                                                  ]),
                                              const Divider(height: 32),
                                              Text('Orden de reproducción',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleMedium),
                                              const SizedBox(height: 6),
                                              const Text(
                                                  'Puedes incluir una introducción o un prólogo. Las pistas se reproducen de arriba abajo.'),
                                              const SizedBox(height: 10),
                                              OutlinedButton.icon(
                                                  onPressed: () => _pick(),
                                                  icon: const Icon(Icons
                                                      .library_music_outlined),
                                                  label: const Text(
                                                      'Añadir archivos de audio')),
                                              const SizedBox(height: 12)
                                            ]);
                                      final index = i - 1, t = _tracks[index];
                                      return Padding(
                                          key: ObjectKey(t),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 4),
                                          child: Row(children: [
                                            SizedBox(
                                                width: 35,
                                                child: Text('${index + 1}')),
                                            Expanded(
                                                child: TextFormField(
                                                    key: ObjectKey(t),
                                                    initialValue: t.title,
                                                    onChanged: (s) =>
                                                        t.title = s,
                                                    decoration:
                                                        const InputDecoration(
                                                            labelText:
                                                                'Nombre de la pista',
                                                            isDense: true))),
                                            IconButton(
                                                tooltip: 'Subir',
                                                onPressed: index == 0
                                                    ? null
                                                    : () =>
                                                        _move(index, index - 1),
                                                icon: const Icon(
                                                    Icons.arrow_upward)),
                                            IconButton(
                                                tooltip: 'Bajar',
                                                onPressed: index + 1 ==
                                                        _tracks.length
                                                    ? null
                                                    : () =>
                                                        _move(index, index + 1),
                                                icon: const Icon(
                                                    Icons.arrow_downward)),
                                            IconButton(
                                                tooltip: 'Quitar pista',
                                                onPressed: () => setState(() =>
                                                    _tracks.removeAt(index)),
                                                icon: const Icon(Icons.close))
                                          ]));
                                    })))),
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(children: [
                          Expanded(
                              child: Text(
                                  _error ??
                                      (_saving
                                          ? 'Copiando archivos…'
                                          : 'Los archivos se copian al servidor al guardar.'),
                                  style: TextStyle(
                                      color: _error == null
                                          ? null
                                          : Theme.of(context)
                                              .colorScheme
                                              .error))),
                          FilledButton.icon(
                              onPressed: _saving ? null : _save,
                              icon: const Icon(Icons.check),
                              label: const Text('Guardar'))
                        ]))
                  ])))));
}
