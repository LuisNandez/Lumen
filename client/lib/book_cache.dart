import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared/audiobook.dart';
import 'api.dart';

String bookKey(String value) => sha256.convert(utf8.encode(value)).toString();
String bookServer(String host) {
  final uri = Uri.parse(host.contains('://') ? host : 'http://$host');
  return uri.origin.toLowerCase();
}

class BookCopy {
  const BookCopy(this.book, this.folder, this.complete);
  final AudioBook book;
  final Directory folder;
  final bool complete;
  File asset(String id) {
    final ext = RegExp(r'\.[a-zA-Z0-9]{1,5}$').firstMatch(id)?.group(0) ?? '';
    return File('${folder.path}/${bookKey(id)}$ext');
  }
}

/// A revision is published only after every track and cover is fully on disk.
class BookCache {
  BookCache(String root, String server)
      : root = Directory('$root/audiobooks/${bookKey(server)}');
  final Directory root;
  Map<String, BookCopy> read() {
    final result = <String, BookCopy>{};
    if (!root.existsSync()) return result;
    for (final dir
        in root.listSync(followLinks: false).whereType<Directory>()) {
      for (final name in ['book.json', 'pending.json']) {
        final file = File('${dir.path}/$name');
        if (!file.existsSync()) continue;
        try {
          final book = AudioBook.fromJson(
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
          if (book.tracks.isEmpty) continue;
          final copy = BookCopy(book, dir, name == 'book.json');
          final intact = !copy.complete ||
              book.tracks.every((t) => copy.asset(t.id).existsSync());
          result[book.id] = intact ? copy : BookCopy(book, dir, false);
          break;
        } on Object {
          continue;
        }
      }
    }
    return result;
  }

  Future<BookCopy> download(Api api, AudioBook book, CancelToken cancel,
      void Function(double) progress) async {
    final dir = Directory('${root.path}/${bookKey(book.id)}');
    await dir.create(recursive: true);
    final copy = BookCopy(book, dir, true);
    final pending = File('${dir.path}/pending.json');
    await pending.writeAsString(jsonEncode(book.toJson()), flush: true);
    final assets = <String, String>{
      for (final t in book.tracks) t.id: api.bookTrackUrl(book, t),
      if (book.poster != null) book.poster!: api.bookArtUrl(book, 'poster'),
      if (book.backdrop != null)
        book.backdrop!: api.bookArtUrl(book, 'backdrop'),
    };
    var count = 0;
    for (final a in assets.entries) {
      if (cancel.isCancelled) throw cancel.cancelError!;
      final dest = copy.asset(a.key);
      if (!await dest.exists()) {
        final part = File('${dest.path}.part');
        final offset = await part.exists() ? await part.length() : 0;
        Future<Response<ResponseBody>> fetch(int start) =>
            api.bookBytes(a.value, start, cancel);
        var res = await fetch(offset);
        if (res.statusCode == 416) {
          await res.data!.stream.drain<void>();
          if (await part.exists()) await part.delete();
          res = await fetch(0);
        }
        final append = res.statusCode == 206;
        var received = append ? offset : 0;
        final length = int.tryParse(res.headers.value('content-length') ?? '');
        if (length == null ||
            length <= 0 ||
            (append &&
                !(res.headers.value('content-range') ?? '')
                    .startsWith('bytes $offset-'))) {
          await res.data!.stream.drain<void>();
          throw const FormatException('Respuesta de descarga incompleta');
        }
        final total = received + length;
        final sink =
            await part.open(mode: append ? FileMode.append : FileMode.write);
        try {
          await for (final chunk in res.data!.stream) {
            await sink.writeFrom(chunk);
            received += chunk.length;
            progress((count + received / total) / assets.length);
          }
        } finally {
          await sink.close();
        }
        if (received != total)
          throw const FormatException('Descarga interrumpida');
        await part.rename(dest.path);
      }
      progress(++count / assets.length);
    }
    if (cancel.isCancelled) throw cancel.cancelError!;
    await pending.rename('${dir.path}/book.json');
    return copy;
  }
}
