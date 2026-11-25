# Modo TV — pasos 4 y 5: ajustes y entrada de texto con el mando

Copia los archivos sobre los del proyecto, respetando las rutas (parten del estado con los pasos 1–3 ya aplicados):

- client/lib/tv.dart          (paso 5: nuevo `TvTextEntry` y `TvScrollTopOnFocus`)
- client/lib/settings.dart    (paso 4: casi todo)
- client/lib/downloads.dart   (4: `confirmAction` con el foco en "Cancelar"; 5: buscador de descargas)
- client/lib/updater.dart     (4: el diálogo de actualización empieza en su botón principal)
- client/lib/profiles.dart    (4: teclado de PIN con foco en el 5; 5: nombre de usuario)
- client/lib/main.dart        (5: IP y PIN de la conexión)
- client/lib/peticiones.dart  (5: buscador y año de los filtros)
- client/lib/sala.dart        (5: buscador de "¿Qué vais a ver?")
- client/lib/theater.dart     (5: buscador del teatro, editar ficha, búsqueda TMDB)
- README.md                   (Fase 18 completa)

No se ha compilado (no hay Flutter donde se escribió; solo comprobé que los paréntesis cuadran): si `flutter analyze` marca algo, avísame.

## Paso 4 — Ajustes
- Columna centrada de ≤ 900 dp (en 1920 px las filas quedaban gigantes) y lista con margen de construcción para que ▼ siempre tenga fila.
- Cada fila y la tarjeta de perfil llevan **aro blanco** al enfocarlas (solo en TV y navegando con teclas).
- El interruptor de "Reanudar solas" ya no es una parada de foco aparte: OK sobre la fila lo cambia.
- "Descargas simultáneas": el segmento enfocado lleva aro.
- Se oculta "Sin restricción de batería" en TV.
- Diálogos de confirmación: foco inicial en **Cancelar** (un OK sin querer no borra nada). Diálogo de actualización: foco en Instalar / Cancelar / Cerrar según el estado.
- Teclado de PIN: foco inicial en el **5**, flechas entre teclas; las cifras de un mando con teclado numérico siguen funcionando.
- Las filas sin acción (estado del servidor, "Este dispositivo", "Acerca de") no reciben foco: se leen, no se pulsan.

## Paso 5 — Entrada de texto con el mando (`TvTextEntry`)
Envuelve el `TextField` tal cual (mismo controlador y decoración). Fuera de TV devuelve el hijo sin tocar.

Sin editar:
- El campo es un elemento más del foco, con aro blanco; las flechas pasan de largo.
- **OK** empieza a editar y abre el teclado de la TV.

Editando:
- El teclado de la TV recibe las flechas.
- Al cerrarlo (Atrás o ✓) se deja de editar y el foco **se queda en el campo**.
- Sin teclado en pantalla (o con teclado físico): ▲/▼ salen del campo; ◀/▶ salen al llegar al principio/final del texto; Esc/Atrás dejan de editar; OK reabre el teclado.
- En campos de varias líneas, ▲/▼ solo salen desde el principio/final.
- Los buscadores que se abren con la lupa (teatro, descargas) empiezan ya escribiendo.

Campos cubiertos: IP y PIN de conexión, buscador y año de Peticiones, nombre de usuario, buscador de Sala, buscador del teatro y de descargas, editar ficha (título, sinopsis...) y búsqueda TMDB.

## Volver arriba al enfocar el cartel
`TvScrollTopOnFocus` (en `tv.dart`) envuelve los botones de arriba: Reproducir/Reanudar y "Más información" del cartel de Inicio, y Reproducir, "Ver en otro dispositivo" y "Más opciones" de las fichas de película y serie. Al enfocarlos con el mando, la pantalla anima hasta el principio (como las apps de streaming), así la cabecera se ve y la flecha de volver ya no se solapa con el botón. Con el dedo no actúa.

## Limitaciones conocidas
- El botón "✕" que algunos campos llevan dentro (limpiar búsqueda en Peticiones) no se alcanza con el mando mientras no se edita; con el teclado de la TV se borra normalmente.
- Hace falta un teclado instalado en la TV (Gboard o el de Android TV). Sin él, OK no mostrará nada.
- Con el campo de Peticiones en edición, ▼ sale del campo y esconde las sugerencias: para ir a ellas, envía la búsqueda con ✓ del teclado.

## Para probar
flutter run --dart-define=TV=true   (en escritorio: flechas, Enter para editar, Esc para salir del campo)
