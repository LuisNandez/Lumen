import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'core.dart';

// ===========================================================================
//  Tamaño de los subtítulos.
//  1.0 es el tamaño de siempre (el estilo por defecto de media_kit); el control
//  solo permite agrandarlos, hasta [kSubScaleMax] veces. Se ajusta desde el menú del
//  reproductor (pestaña Subtítulos), donde el cambio se ve en los subtítulos reales.
// ===========================================================================

const double kSubScaleMin = 1.0;
const double kSubScaleMax = 2.5;
const int _kSubDivisions = 15; // pasos de 0,1

const _red = Color(0xFFE50914);

/// Configuración de los subtítulos del reproductor para un tamaño dado.
/// Con 1.0 devuelve exactamente la de por defecto, así nada cambia hasta que se elija.
SubtitleViewConfiguration subtitleConfig(double scale) {
  const base = SubtitleViewConfiguration();
  if (scale <= kSubScaleMin) return base;
  return SubtitleViewConfiguration(
    style: base.style.copyWith(fontSize: (base.style.fontSize ?? 32.0) * scale),
    textAlign: base.textAlign,
    padding: base.padding,
  );
}

String _scaleLabel(double s) =>
    s <= kSubScaleMin ? 'Normal' : '${(s * 100).round()} %';

/// Control del tamaño de los subtítulos para el menú del reproductor: una sola fila con la barra.
/// Cada cambio se guarda y se aplica al momento. [onActive] avisa cuando se empieza (true) y se
/// termina (false) de mover la barra, para que el menú se oculte y deje ver los subtítulos.
class SubtitleSizeControl extends ConsumerWidget {
  const SubtitleSizeControl({super.key, this.onActive});
  final ValueChanged<bool>? onActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(settingsProvider.select((s) => s.subtitleScale));
    final ctl = ref.read(settingsProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
      child: Row(children: [
        const Icon(Icons.format_size_rounded, size: 20, color: Colors.white54),
        const SizedBox(width: 10),
        const Text('Tamaño',
            style: TextStyle(color: Colors.white70, fontSize: 13.5)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: _red,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white12),
            child: Slider(
                value: scale.clamp(kSubScaleMin, kSubScaleMax).toDouble(),
                min: kSubScaleMin,
                max: kSubScaleMax,
                divisions: _kSubDivisions,
                onChangeStart: (_) => onActive?.call(true),
                // Con el mando (◀ ▶) no hay "empezar/terminar": cada cambio avisa por su cuenta
                // para que el menú se aparte y se vean los subtítulos reales.
                onChanged: (v) {
                  onActive?.call(true);
                  ctl.setSubtitleScale(v);
                  onActive?.call(false);
                },
                onChangeEnd: (_) => onActive?.call(false)),
          ),
        ),
        GestureDetector(
          onTap: () {
            onActive?.call(true);
            ctl.setSubtitleScale(kSubScaleMin);
            onActive?.call(false);
          },
          child: SizedBox(
              width: 54,
              child: Text(_scaleLabel(scale),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scale <= kSubScaleMin
                          ? Colors.white70
                          : Colors.orangeAccent))),
        ),
      ]),
    );
  }
}