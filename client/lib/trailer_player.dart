// client/lib/trailer_player.dart
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' hide Video;

import 'tmdb.dart';
import 'tv.dart' show TvFocusable;

/// Tráiler de una película de TMDB dentro de la app (con el reproductor de media_kit,
/// sin abrir YouTube). El servidor propone un tráiler de TMDB; si no es claramente en
/// español latino, aquí se busca en YouTube uno "español latino" y, si aparece, se usa ese.
class TrailerPlayer extends StatefulWidget {
  const TrailerPlayer({
    super.key,
    required this.catalog,
    required this.tmdbId,
    this.title,
    this.year,
    this.type = 'movie', // 'movie' | 'tv'
    this.autoplay = false, // true = empieza solo al abrir la ficha
    this.tv =
        false, // modo TV: se maneja con el mando (OK reproduce, pausa y reanuda)
  });

  final Catalog catalog;
  final int tmdbId;
  final String? title; // para buscar la versión latina en YouTube
  final int? year;
  final String type;
  final bool autoplay;
  final bool tv;

  @override
  State<TrailerPlayer> createState() => _TrailerPlayerState();
}

class _TrailerPlayerState extends State<TrailerPlayer> {
  static final _reLatino = RegExp(r'latino|latam|latinoam|hispanoam|m[eé]xico',
      caseSensitive: false);
  static final _reTrailer =
      RegExp(r'tr[áa]iler|trailer|teaser|avance', caseSensitive: false);
  static final _reMalo = RegExp(
      r'reacci[óo]n|reaction|rese[ñn]a|review|an[áa]lisis|explicaci[óo]n|castellano|espa[ñn]a',
      caseSensitive: false);

  Player? _player;
  VideoController? _controller;
  String? _key; // video de YouTube elegido
  String? _lang; // 'es' | 'en' | otro
  bool _latino = false;
  bool _loading = true, _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _find();
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[áàä]'), 'a')
      .replaceAll(RegExp(r'[éèë]'), 'e')
      .replaceAll(RegExp(r'[íìï]'), 'i')
      .replaceAll(RegExp(r'[óòö]'), 'o')
      .replaceAll(RegExp(r'[úùü]'), 'u')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Busca en YouTube el tráiler en español latino (canales "Latinoamérica", "Latam"...).
  Future<String?> _searchLatino(String title, int? year) async {
    final yt = YoutubeExplode();
    try {
      final q =
          '$title${year != null ? ' $year' : ''} tráiler oficial español latino';
      final results =
          await yt.search.search(q).timeout(const Duration(seconds: 12));
      final wanted = _norm(title);
      for (final r in results.take(10)) {
        final d = r.duration;
        if (d != null && d.inMinutes >= 6) continue;
        if (!_reLatino.hasMatch('${r.title} ${r.author}')) continue;
        if (!_reTrailer.hasMatch(r.title) || _reMalo.hasMatch(r.title))
          continue;
        if (!_norm(r.title).contains(wanted)) continue;
        return r.id.value;
      }
    } catch (_) {
      // sin internet o YouTube cambió: se queda el de TMDB
    } finally {
      yt.close();
    }
    return null;
  }

  Future<void> _find() async {
    try {
      final t =
          await widget.catalog.movieTrailer(widget.tmdbId, type: widget.type);
      String? key = t?['key'] as String?;
      var latino = t?['latino'] == true;
      if (!latino && widget.title != null && widget.title!.isNotEmpty) {
        final found = await _searchLatino(widget.title!, widget.year);
        if (found != null) {
          key = found;
          latino = true;
        }
      }
      if (!mounted) return;
      setState(() {
        _key = key;
        _lang = latino ? 'es' : t?['lang'] as String?;
        _latino = latino;
        _loading = false;
      });
      if (key != null && widget.autoplay) _play();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'No se pudo buscar el tráiler.';
        });
      }
    }
  }

  Future<void> _play() async {
    final key = _key;
    if (key == null || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient
          .getManifest(key)
          .timeout(const Duration(seconds: 20));
      // Streams con video y audio juntos (YouTube los da hasta ~360p/720p).
      final stream = manifest.muxed.reduce(
          (a, b) => a.bitrate.bitsPerSecond >= b.bitrate.bitsPerSecond ? a : b);
      final player = Player();
      final controller = VideoController(player);
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _controller = controller;
      });
      await player.open(Media(stream.url.toString()));
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'No se pudo reproducir el tráiler (este dispositivo necesita internet).');
      }
    } finally {
      yt.close();
      if (mounted) setState(() => _starting = false);
    }
  }

  String get _label {
    if (_latino) return 'Tráiler · español latino';
    if (_lang == 'es') return 'Tráiler · español';
    return 'Tráiler · ${_lang == 'en' ? 'inglés' : 'idioma original'}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black26,
          child: Center(
              child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      );
    }
    final key = _key;
    if (key == null) {
      // Sin tráiler: no se muestra nada (o el error de red si lo hubo).
      return _error == null
          ? const SizedBox.shrink()
          : Text(_error!, style: const TextStyle(color: Colors.white54));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_label, style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: _controller != null
                ? (widget.tv
                    // TV: el vídeo es un elemento enfocable; OK pausa y reanuda. Sin los
                    // controles táctiles de media_kit (con el mando no se pueden usar).
                    ? TvFocusable(
                        autofocus: true,
                        scale: 1,
                        borderRadius: 10,
                        nearestScrollOnly: true,
                        onTap: () => _player?.playOrPause(),
                        child: Video(
                            controller: _controller!,
                            controls: NoVideoControls))
                    : Video(controller: _controller!))
                : Stack(fit: StackFit.expand, children: [
                    Image.network(
                      'https://img.youtube.com/vi/$key/hqdefault.jpg',
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const ColoredBox(color: Colors.black),
                    ),
                    const ColoredBox(color: Colors.black38),
                    Center(
                      child: _starting
                          ? const CircularProgressIndicator()
                          : IconButton.filled(
                              iconSize: widget.tv ? 56 : 40,
                              onPressed: _play,
                              icon: const Icon(Icons.play_arrow)),
                    ),
                  ]),
          ),
        ),
        if (widget.tv && _controller != null)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('OK: pausar / reanudar',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ),
      ],
    );
  }
}
