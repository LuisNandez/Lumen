# Modo TV — paso 3: reproductor con mando (acumulado: incluye pasos 1 y 2)

Copia los archivos sobre los del proyecto, respetando las rutas:

- client/lib/player_controls.dart  (paso 3: casi todo)
- client/lib/main.dart             (paso 3: PlayerScreen pasa tv y el botón de saltar)
- client/lib/track_menu.dart       (paso 3: el foco empieza en la opción elegida)
- client/lib/tv.dart               (pasos 1 y 3: tecla Menú; nuevo `focusSide`)
- client/lib/theater.dart, client/lib/downloads.dart  (pasos 1 y 2, sin cambios nuevos)
- README.md                        (Fase 18 actualizada)

No se ha compilado (no hay Flutter donde se escribió): si `flutter analyze` marca algo, avísame.

## Cómo se maneja (solo TV; móvil y escritorio no cambian)

Controles ocultos (o foco en el reproductor):
- OK          → pausa / reanuda (y muestra los controles)
- ◀ / ▶       → −10 s / +10 s; se acumulan (−30 s...) y, manteniendo pulsado, siguen (uno cada 300 ms)
- ▲ / ▼       → abren los controles con el foco en el botón de pausa
- ▼ con "Saltar intro / Siguiente episodio" en pantalla → enfoca ese botón; OK lo pulsa
- Teclas multimedia (play/pausa, adelantar, retroceder) funcionan siempre, también en móvil/escritorio

Controles abiertos con el foco en un botón: las flechas mueven el foco (volver · −10 · pausa · +10 ·
velocidad · Ver juntos · pistas) y OK pulsa. Sin actividad se ocultan a los 6 s y el foco vuelve al reproductor.
Atrás (mando) sale del reproductor como siempre.

## Detalles
- En TV no se muestra el volumen (el del mando) ni imagen en imagen.
- El botón de saltar va dentro de PlayerControls (parámetro `skip`) para estar en su foco; en móvil sigue donde estaba.
- Botones centrales con aro blanco al enfocar; "Saltar" (botón blanco) con aro rojo.
- Menú de pistas/subtítulos: el foco empieza en la opción marcada.

## Para probar
flutter run --dart-define=TV=true   (en escritorio: flechas, Enter, y la tecla de menú del teclado no aplica)
