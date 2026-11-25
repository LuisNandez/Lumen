import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared/audiobook.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'book_cache.dart';

/// Stable across item reordering, separate for each server and profile.
String listeningKey(Api api, String profile, AudioBook b) => bookKey(
    jsonEncode([bookServer(api.host), profile.trim().toLowerCase(), b.id]));

class ListeningState {
  const ListeningState(
      {this.track = '',
      this.position = 0,
      this.duration = 0,
      this.active = false,
      this.playing = false,
      this.ended = false,
      this.local = false,
      this.error});
  final String track;
  final int position, duration;
  final bool active, playing, ended, local;
  final String? error;
  factory ListeningState.from(Map m) => ListeningState(
      track: m['track'] ?? '',
      position: m['position'] ?? 0,
      duration: m['duration'] ?? 0,
      active: m['active'] == true,
      playing: m['playing'] == true,
      ended: m['ended'] == true,
      local: m['local'] == true,
      error: m['error']);
}

class BookPlayback {
  static const channel = MethodChannel('lumen/book_audio');
  static Player? _player;
  static Map<String, dynamic>? _queue;
  static Timer? _clock;
  static StreamSubscription<bool>? _completion;
  static bool _ready = false;
  static Future<Map> _saved(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return jsonDecode(prefs.getString('book.place.$key') ?? '{}') as Map;
  }

  static Map<String, dynamic> _position() {
    final p = _player!, q = _queue!;
    final ids = q['ids'] as List;
    final i = p.state.playlist.index;
    if (i < 0 || i >= ids.length) return {};
    return {
      'track': ids[i],
      'position': p.state.position.inMilliseconds,
      'duration': p.state.duration.inMilliseconds,
      'ended': p.state.completed && i == ids.length - 1
    };
  }

  static Future<void> _save() async {
    if (!_ready || _player == null || _queue == null) return;
    final key = _queue!['key'], value = jsonEncode(_position());
    await (await SharedPreferences.getInstance())
        .setString('book.place.$key', value);
  }

  static Future<ListeningState> status(String key) async {
    if (Platform.isAndroid)
      return ListeningState.from(
          await channel.invokeMapMethod('status', {'key': key}) ?? {});
    if (_ready && _queue?['key'] == key && _player != null) {
      return ListeningState.from({
        ..._position(),
        'active': true,
        'playing': _player!.state.playing,
        'local': _queue!['local']
      });
    }
    return ListeningState.from(await _saved(key));
  }

  static Future<void> open(Api api, AudioBook book, String key, BookCopy? copy,
      {int index = -1}) async {
    final local =
        copy != null && book.tracks.every((t) => copy.asset(t.id).existsSync());
    final coverId = book.poster ?? book.backdrop;
    final coverFile = coverId == null ? null : copy?.asset(coverId);
    final args = <String, dynamic>{
      'key': key,
      'title': book.title,
      'author': book.author,
      'local': local,
      'index': index,
      'detail': jsonEncode({'key': key, 'book': book.toJson()}),
      'ids': [for (final t in book.tracks) t.id],
      'titles': [for (final t in book.tracks) t.title],
      'urls': [
        for (final t in book.tracks)
          local ? copy.asset(t.id).uri.toString() : api.bookTrackUrl(book, t)
      ],
      'headers': api.authHeaders,
      'cover': coverFile != null && coverFile.existsSync()
          ? coverFile.uri.toString()
          : coverId == null
              ? ''
              : api.bookArtUrl(
                  book, book.poster != null ? 'poster' : 'backdrop')
    };
    if (Platform.isAndroid) {
      await channel.invokeMethod('open', args);
      return;
    }
    await stop();
    final mark = await _saved(key);
    var ms = 0;
    if (index < 0) {
      index = book.tracks.indexWhere((t) => t.id == mark['track']);
      if (index >= 0 && mark['ended'] != true) {
        ms = mark['position'] ?? 0;
      } else {
        index = 0;
      }
    }
    final p = Player();
    _player = p;
    _queue = args;
    try {
      await p.open(
          Playlist([
            for (final u in args['urls'] as List<String>)
              Media(u, httpHeaders: local ? null : api.authHeaders)
          ], index: index),
          play: false);
      if (ms > 0) await p.seek(Duration(milliseconds: ms));
      await p.play();
      _ready = true;
      _clock = Timer.periodic(const Duration(seconds: 4), (_) => _save());
      _completion = p.stream.completed.listen((_) => _save());
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  static Future<void> command(String key, String action,
      [int value = 0]) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod(
          'command', {'key': key, 'action': action, 'value': value});
      return;
    }
    final p = _player;
    if (p == null || _queue?['key'] != key) return;
    switch (action) {
      case 'play':
        await p.play();
      case 'pause':
        await p.pause();
      case 'seek':
        await p.seek(Duration(milliseconds: value));
      case 'jump':
        await p.jump(value);
        await p.play();
      case 'stop':
        await stop();
        return;
    }
    await _save();
  }

  static Future<void> stop([String? key]) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('command', {'key': key, 'action': 'stop'});
      return;
    }
    if (key != null && _queue?['key'] != key) return;
    await _save();
    _ready = false;
    _clock?.cancel();
    await _completion?.cancel();
    final p = _player;
    _player = null;
    _queue = null;
    await p?.dispose();
  }
}
