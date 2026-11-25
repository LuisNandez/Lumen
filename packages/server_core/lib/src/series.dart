import 'package:path/path.dart' as p;

import 'metadata.dart';

/// Datos de un capítulo deducidos de la ruta del archivo (carpeta + nombre).
class EpisodeInfo {
  const EpisodeInfo(this.show, this.key, this.season, this.episode,
      {this.year, this.title});

  /// Nombre limpio de la serie (sale de la carpeta; "Breaking Bad (2008)" → "Breaking Bad").
  final String show;

  /// Clave estable para agrupar los capítulos de una misma serie.
  final String key;

  /// Temporada (0 = especiales) y número de capítulo.
  final int season, episode;
  final int? year;

  /// Nombre del capítulo si venía en el archivo ("S01E02 Cat's in the Bag").
  final String? title;
}

// "Season 1", "Temporada 02", "S3", "2ª Temporada", "Temporada 1 - Algo"
final _seasonDir = RegExp(
    r'^(?:(?:season|temporada|temp|s)[\s._-]*(\d{1,2})|(\d{1,2})\s*[ªa]?\s*temporada)(?:[\s(\[._-].*)?$',
    caseSensitive: false);
final _specialsDir = RegExp(r'^(?:specials?|especiales|extras?|featurettes?)$',
    caseSensitive: false);
// Para carpetas tipo "Breaking.Bad.S01.1080p"
final _seasonInName = RegExp(
    r'\b(?:s|season\s*|temporada\s*|temp\s*)(\d{1,2})\b',
    caseSensitive: false);

final _reSxE = RegExp(r'\bS(\d{1,2})[ ._-]?E(\d{1,3})(?:[ ._-]?E\d{1,3})*\b',
    caseSensitive: false);
final _reNxN = RegExp(r'\b(\d{1,2})x(\d{2,3})\b', caseSensitive: false);
final _reTemp = RegExp(
    r'\b(?:temporada|temp|season)\s*(\d{1,2})\s*[,.\-]?\s*(?:cap[ií]tulo|cap|episodio|episode|ep)\s*\.?\s*(\d{1,3})\b',
    caseSensitive: false);
final _reCap = RegExp(
    r'\b(cap[ií]tulo|cap|episodio|episode|ep)\s*\.?\s*(\d{1,3})\b',
    caseSensitive: false);
final _reNum = RegExp(r'^\s*(\d{1,3})(?=\s|-|\.|$)');

final _tags = RegExp(
    r'\b(2160p|1080p|720p|480p|4k|uhd|bluray|blu-ray|brrip|bdrip|webrip|web-dl|webdl|hdrip|dvdrip|hdtv|x264|x265|h264|h265|hevc|hdr|remux|latino|castellano|dual|multi|amzn|proper|repack)\b',
    caseSensitive: false);

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

({String title, int? year}) _cleanShow(String raw) {
  final n = MetadataStore.parseName(raw);
  final t = n.title
      .replaceAll(
          RegExp(
              r'\b(?:S\d{1,2}(?:E\d{1,3})?|season\s*\d+|temporada\s*\d+|temp\s*\d+)\b.*$',
              caseSensitive: false),
          '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return (title: t, year: n.year);
}

({int season, int episode, int start, int end})? _find(
    String name, bool hasSeasonDir, int? dirSeason, bool inFolder) {
  RegExpMatch? m = _reSxE.firstMatch(name);
  if (m != null) {
    return (
      season: int.parse(m.group(1)!),
      episode: int.parse(m.group(2)!),
      start: m.start,
      end: m.end
    );
  }
  m = _reNxN.firstMatch(name);
  if (m != null) {
    return (
      season: int.parse(m.group(1)!),
      episode: int.parse(m.group(2)!),
      start: m.start,
      end: m.end
    );
  }
  m = _reTemp.firstMatch(name);
  if (m != null) {
    return (
      season: int.parse(m.group(1)!),
      episode: int.parse(m.group(2)!),
      start: m.start,
      end: m.end
    );
  }
  // "Capítulo 5" solo cuenta si hay carpeta de temporada, o si es "cap/capítulo"
  // dentro de una carpeta (evita convertir "Star Wars Episode 4" en una serie).
  m = _reCap.firstMatch(name);
  if (m != null &&
      (hasSeasonDir ||
          (inFolder && m.group(1)!.toLowerCase().startsWith('cap')))) {
    return (
      season: dirSeason ?? 1,
      episode: int.parse(m.group(2)!),
      start: m.start,
      end: m.end
    );
  }
  // "05 - Nombre.mkv" solo dentro de una carpeta "Temporada N".
  if (hasSeasonDir) {
    m = _reNum.firstMatch(name);
    if (m != null) {
      return (
        season: dirSeason ?? 1,
        episode: int.parse(m.group(1)!),
        start: m.start,
        end: m.end
      );
    }
  }
  return null;
}

/// Devuelve los datos del capítulo si el archivo parece de una serie; null si es película.
///
/// La serie se toma del nombre de la carpeta (saltando las carpetas "Temporada N");
/// solo si el archivo está suelto en la raíz se usa el principio del nombre del archivo.
EpisodeInfo? parseEpisode(String root, String path) {
  final parts = p.split(p.relative(path, from: root));
  final dirs = parts.sublist(0, parts.length - 1);
  final name =
      p.basenameWithoutExtension(path).replaceAll(RegExp(r'[._]+'), ' ').trim();

  int? dirSeason;
  var hasSeasonDir = false;
  for (final d in dirs.reversed) {
    final m = _seasonDir.firstMatch(d);
    if (m != null) {
      dirSeason = int.parse(m.group(1) ?? m.group(2)!);
      hasSeasonDir = true;
      break;
    }
    if (_specialsDir.hasMatch(d)) {
      dirSeason = 0;
      hasSeasonDir = true;
      break;
    }
  }
  if (dirSeason == null) {
    for (final d in dirs.reversed) {
      final m = _seasonInName.firstMatch(d.replaceAll(RegExp(r'[._]+'), ' '));
      if (m != null) {
        dirSeason = int.parse(m.group(1)!);
        hasSeasonDir = true;
        break;
      }
    }
  }

  final f = _find(name, hasSeasonDir, dirSeason, dirs.isNotEmpty);
  if (f == null) return null;

  String? showRaw;
  for (final d in dirs.reversed) {
    if (_seasonDir.hasMatch(d) || _specialsDir.hasMatch(d)) continue;
    showRaw = d;
    break;
  }
  var n = (title: '', year: null as int?);
  if (showRaw != null) n = _cleanShow(showRaw);
  if (n.title.isEmpty) {
    n = _cleanShow(
        name.substring(0, f.start).replaceAll(RegExp(r'\[[^\]]*\]'), ' '));
  }
  if (n.title.isEmpty) return null;

  var tail =
      name.substring(f.end).replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)'), ' ');
  final t = _tags.firstMatch(tail);
  if (t != null) tail = tail.substring(0, t.start);
  tail = tail
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s\-–:.]+|[\s\-–:.]+$'), '');

  return EpisodeInfo(
    n.title,
    '${_norm(n.title)}${n.year != null ? '_${n.year}' : ''}',
    f.season,
    f.episode,
    year: n.year,
    title: tail.length >= 2 ? tail : null,
  );
}

/// Nombre de la subcarpeta de una temporada: "Temporada 01" ("Especiales" para la 0).
/// Es de las que [parseEpisode] y [folderGroup] reconocen como carpeta de temporada.
String seasonFolderName(int season) =>
    season == 0 ? 'Especiales' : 'Temporada ${season.toString().padLeft(2, '0')}';

/// Carpeta de la serie a la que pertenece el archivo [path]: la más cercana a él que no sea
/// de temporada ("Temporada 2", "Especiales"...). null si el archivo está suelto en la raíz.
String? showFolder(String root, String path) {
  final parts = p.split(p.relative(path, from: root));
  final dirs = parts.sublist(0, parts.length - 1);
  for (var i = dirs.length - 1; i >= 0; i--) {
    final d = dirs[i];
    if (_seasonDir.hasMatch(d) || _specialsDir.hasMatch(d)) continue;
    return p.joinAll([root, ...dirs.sublist(0, i + 1)]);
  }
  return null;
}

/// Temporada y capítulo que sugiere el nombre de [path] ("S02E05", "2x05", "Capítulo 5",
/// "05 - Nombre"...). [explicitSeason] es false si el nombre solo traía el capítulo (la
/// temporada se da por la 1). null si el nombre no trae ningún número de capítulo.
({int season, int episode, bool explicitSeason})? guessEpisode(String path) {
  final name =
      p.basenameWithoutExtension(path).replaceAll(RegExp(r'[._]+'), ' ').trim();
  final f = _find(name, true, null, true);
  if (f == null) return null;
  final explicit =
      _reSxE.hasMatch(name) || _reNxN.hasMatch(name) || _reTemp.hasMatch(name);
  return (season: f.season, episode: f.episode, explicitSeason: explicit);
}

/// Si el video está dentro de una carpeta (no en la raíz), devuelve la "serie"
/// que forma esa carpeta. Salta las carpetas "Temporada N" / "Especiales".
/// Se usa para agrupar videos sin formato de capítulo (S01E02, 1x02...).
({String name, String key, int season, int? year})? folderGroup(
    String root, String path) {
  final parts = p.split(p.relative(path, from: root));
  final dirs = parts.sublist(0, parts.length - 1);
  int? season;
  for (final d in dirs.reversed) {
    final m = _seasonDir.firstMatch(d);
    if (m != null) {
      season ??= int.parse(m.group(1) ?? m.group(2)!);
      continue;
    }
    if (_specialsDir.hasMatch(d)) {
      season ??= 0;
      continue;
    }
    final n = _cleanShow(d);
    final name = n.title.isEmpty ? d : n.title;
    return (
      name: name,
      key: '${_norm(name)}${n.year != null ? '_${n.year}' : ''}',
      season: season ?? 1,
      year: n.year
    );
  }
  return null; // en la raíz: se queda como película
}
