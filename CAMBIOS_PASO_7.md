# Paso 7 — Sonidos de la interfaz

Copia cada archivo en su misma ruta, sobrescribiendo. Después, en `client/`:

    flutter pub get

(Se añade el paquete `audioplayers`. `pubspec.lock` se regenera solo.)

IMPORTANTE: `pubspec.yaml` ahora declara también `assets/sounds/`. Con solo `assets/` Flutter
NO incluye las subcarpetas, así que sin esa línea los mp3 no entran en la app.

## Dónde suena cada sonido
| Archivo | Suena cuando |
|---|---|
| s_intro_al inicia_app | Al abrir la app |
| s_desplazamiento_interfaz | El foco se mueve entre elementos con flechas / mando (carátulas, botones, filas, menú lateral ▲▼) |
| s_desplazamiento_interfaz_2 | Cambio de zona o sección: menú lateral ↔ pantalla, pestañas de la barra inferior |
| s_entrar | Tocar / OK en una carátula o tarjeta, y al pulsar Reproducir |
| s_salir_o_atras | Cerrar una pantalla completa (Navigator), Atrás en el shell |
| s_empezar_descarga | Empieza o se reanuda una descarga (una o varias) |
| s_notificacion | Capítulo nuevo, petición disponible, descarga completada, invitación a una sala, actualización |
| s_marcar_visto_notificaciones | Abrir un aviso de la campanita / "Marcar todo como leído" |
| s_entrar_a_sala | Te sientas en una sala de "ver juntos" |
| s_salirde_sala | Sales de una sala |
| s_alerta | Errores (snackbars rojos), diálogos de confirmación (borrar...), servidor que deja de responder |

## Cómo funciona
- `client/lib/sounds.dart` (nuevo): todo el sistema. `Sfx.play(Snd.xxx)`.
  - Volumen y enfriamiento por sonido en el enum `Snd` (edita ahí si alguno suena fuerte o flojo).
  - El "tic" de foco es un único oyente global: solo suena si el foco cambió justo tras pulsar una
    flecha (no al abrir pantallas ni al tocar con el dedo).
  - No pide foco de audio en Android: no pausa ni baja otras apps.
  - Con un video en pantalla callan los sonidos de navegación; avisos y salas suenan igualmente.
- Ajustes → Reproducción → "Sonidos de la interfaz" (interruptor, activado por defecto).
- `errorSnack(texto)` sustituye a `SnackBar(content: Text(errText(e)))` y ya suena el aviso.
  Para un error nuevo: `ScaffoldMessenger.of(context).showSnackBar(errorSnack(errText(e)))`.

## Nota
`s_intro_al inicia_app.mp3` tiene un espacio en el nombre. Debería funcionar, pero si en algún
dispositivo no suena, renómbralo (p. ej. `s_intro_al_inicia_app.mp3`) y cambia solo la línea
`intro(...)` del enum `Snd`.
