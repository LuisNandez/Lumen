import 'package:shared/shared.dart';

/// De dónde sale la posición con la que se reanuda. Decide cuánto hay que fiarse de ella.
enum ResumeSource {
  /// Anotada en este dispositivo y aún no enviada al servidor: lo más reciente que existe.
  pending,

  /// Acaba de pedirse al servidor (ficha o progreso recién descargados): no hace falta verificar.
  fresh,

  /// Copia descargada: la posición vive en el dispositivo.
  local,

  /// Viene de una lista (biblioteca...) y puede estar desfasada: se contrasta con el servidor
  /// durante un margen corto, sin bloquear el arranque.
  list,
}

/// Con qué posición debe arrancar el reproductor. Lo construye quien abre el reproductor.
class ResumeInfo {
  const ResumeInfo({
    this.positionMs = 0,
    this.durationMs,
    this.source = ResumeSource.list,
    this.fromStart = false,
  });

  /// Empezar siempre en 0 (p. ej. "Siguiente episodio").
  const ResumeInfo.start()
      : positionMs = 0,
        durationMs = null,
        source = ResumeSource.fresh,
        fromStart = true;

  /// Posición de una tarjeta de lista: se contrasta con el servidor en segundo plano.
  factory ResumeInfo.fromItem(VideoItem v) => ResumeInfo(
      positionMs: v.positionMs,
      durationMs: v.durationMs,
      source: ResumeSource.list);

  /// Ficha recién pedida al servidor: se usa tal cual, sin más consultas.
  factory ResumeInfo.fresh(VideoItem v) => ResumeInfo(
      positionMs: v.positionMs,
      durationMs: v.durationMs,
      source: ResumeSource.fresh);

  final int positionMs;
  final int? durationMs;
  final ResumeSource source;
  final bool fromStart;

  /// ¿Hay que preguntar al servidor si hay una posición más reciente?
  bool get needsServerCheck => !fromStart && source == ResumeSource.list;
}

/// Ajustes de reproducción que decide la app (no el usuario durante la sesión).
class PlayerSettings {
  const PlayerSettings({
    this.volume,
    this.rewindMs = 3000,
    this.minResumeMs = 5000,
    this.finishedFraction = 0.95,
    this.serverCheckBudget = const Duration(milliseconds: 2500),
    this.detailBudget = const Duration(seconds: 3),
    this.rememberTracks = true,
    this.autoPlay = true,
  });

  /// Volumen inicial (0–150). Null = el recordado entre videos.
  final double? volume;

  /// Cuánto se retrocede al reanudar para recordar la escena.
  final int rewindMs;

  /// Por debajo de esta posición no se reanuda (se empieza desde 0).
  final int minResumeMs;

  /// A partir de esta fracción de la duración se considera el video terminado.
  final double finishedFraction;

  /// Tiempo máximo que se espera al servidor para contrastar la posición antes de abrir.
  final Duration serverCheckBudget;

  /// Tiempo máximo que se espera a la ficha (pistas, subtítulos externos) antes de abrir.
  final Duration detailBudget;

  /// Reponer audio/subtítulos/sincronía recordados.
  final bool rememberTracks;

  /// Empezar a reproducir al abrir.
  final bool autoPlay;
}
