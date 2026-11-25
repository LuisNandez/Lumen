import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shared/audiobook.dart';

const audioTypes = {
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'm4b': 'audio/mp4',
  'aac': 'audio/aac',
  'flac': 'audio/flac',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'oga': 'audio/ogg',
  'opus': 'audio/ogg'
};
const bookImageTypes = {
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp'
};

String? bookMime(String name) =>
    (audioTypes[p.extension(name).toLowerCase().replaceFirst('.', '')] ??
        bookImageTypes[p.extension(name).toLowerCase().replaceFirst('.', '')]);

/// El manifiesto se publica solo cuando todas las copias están completas.
/// Las ediciones reutilizan los archivos ya importados y sus identificadores.
class AudioBookStore {
  AudioBookStore(this.directory, {this.onChanged}) {
    if (!directory.existsSync()) return;
    for (final dir
        in directory.listSync(followLinks: false).whereType<Directory>()) {
      final manifest = File(p.join(dir.path, 'book.json'));
      if (!manifest.existsSync()) continue;
      try {
        final b = AudioBook.fromJson(
            jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>);
        if (b.id != p.basename(dir.path) ||
            b.tracks.isEmpty ||
            !_assets(b).every(
                (n) => RegExp(r'^[0-9a-f]{32}\.[a-z0-9]+$').hasMatch(n))) {
          throw const FormatException('Manifiesto inválido');
        }
        _books[b.id] = b;
      } catch (e) {
        stderr.writeln('No se pudo leer ${manifest.path}: $e');
      }
    }
  }

  final Directory directory;
  final void Function()? onChanged;
  final _books = <String, AudioBook>{};
  final _editing = <String>{};
  final _random = Random.secure();
  String _id() => List.generate(
      16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  List<AudioBook> get books => _books.values.toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  AudioBook? get(String id) => _books[id];
  static Set<String> _assets(AudioBook b) => {
        if (b.poster != null) b.poster!,
        if (b.backdrop != null) b.backdrop!,
        for (final t in b.tracks) t.id
      };
  String assetPath(AudioBook book, String asset) =>
      p.join(directory.path, book.id, asset);

  Future<AudioBook> save(
      {AudioBook? previous,
      required String title,
      required String author,
      required String narrator,
      required String description,
      String? posterPath,
      String? backdropPath,
      required List<({String title, String path})> tracks}) async {
    if (title.trim().isEmpty ||
        tracks.isEmpty ||
        tracks.any((t) => t.title.trim().isEmpty)) {
      throw const FormatException(
          'Escribe el título del libro y de cada pista. Añade al menos un audio.');
    }
    final id = previous?.id ?? _id();
    if (previous?.revision != _books[id]?.revision || !_editing.add(id)) {
      throw StateError('La ficha cambió. Vuelve a abrirla antes de guardar.');
    }
    final dir = Directory(p.join(directory.path, id));
    final existing = previous == null ? <String>{} : _assets(previous);
    final created = <File>[];
    final pending = File(p.join(dir.path, 'book.tmp'));
    Future<String> importAsset(String path, Map<String, String> allowed) async {
      final ext = p.extension(path).toLowerCase();
      if (ext.length < 2 || !allowed.containsKey(ext.substring(1))) {
        throw FormatException('Formato no compatible: ${p.basename(path)}');
      }
      final source = File(path);
      if (!await source.exists() || await source.length() == 0) {
        throw FormatException(
            'Archivo vacío o no disponible: ${p.basename(path)}');
      }
      final name = p.basename(path);
      if (existing.contains(name) && p.equals(dir.path, p.dirname(path)))
        return name;
      final target = File(p.join(dir.path, '${_id()}$ext'));
      created.add(target);
      await source.copy(target.path);
      return p.basename(target.path);
    }

    late AudioBook book;
    try {
      await dir.create(recursive: true);
      book = AudioBook(
          id: id,
          title: title.trim(),
          author: author.trim(),
          narrator: narrator.trim(),
          description: description.trim(),
          revision: (previous?.revision ?? 0) + 1,
          poster: posterPath == null
              ? null
              : await importAsset(posterPath, bookImageTypes),
          backdrop: backdropPath == null
              ? null
              : await importAsset(backdropPath, bookImageTypes),
          tracks: [
            for (final t in tracks)
              BookTrack(await importAsset(t.path, audioTypes), t.title.trim())
          ]);
      await pending.writeAsString(jsonEncode(book.toJson()), flush: true);
      await pending.rename(p.join(dir.path, 'book.json'));
      _books[id] = book;
    } catch (_) {
      for (final f in [...created, pending]) {
        try {
          if (await f.exists()) await f.delete();
        } on FileSystemException {}
      }
      rethrow;
    } finally {
      _editing.remove(id);
    }
    for (final name in existing.difference(_assets(book))) {
      try {
        await File(p.join(dir.path, name)).delete();
      } on FileSystemException {}
    }
    onChanged?.call();
    return book;
  }
}
