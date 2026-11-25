import 'package:flutter/material.dart';

/// Qué significa una clasificación de edades concreta.
class AgeRatingInfo {
  const AgeRatingInfo(this.label, this.title, this.description, this.tier);
  final String label, title, description;

  /// 0 = todo público · 1 = infantil/familiar · 2 = adolescentes · 3 = adultos.
  final int tier;

  Color get color => switch (tier) {
        0 => const Color(0xFF7FC8A0),
        1 => const Color(0xFFE2C26B),
        2 => const Color(0xFFE59A5A),
        _ => const Color(0xFFE0675F),
      };
}

const _countries = {
  'MX': 'México',
  'US': 'Estados Unidos',
  'ES': 'España',
  'AR': 'Argentina',
  'CL': 'Chile',
  'CO': 'Colombia',
  'BR': 'Brasil',
  'GB': 'Reino Unido',
  'DE': 'Alemania',
  'FR': 'Francia',
  'IT': 'Italia',
  'CA': 'Canadá',
};

const _scales = <String, AgeRatingInfo>{
  // México (RTC) — se usa también en series mexicanas.
  'AA': AgeRatingInfo('AA', 'Comprensible para menores de 7 años',
      'Contenido pensado para todo público y apto para niños pequeños.', 0),
  'A': AgeRatingInfo('A', 'Para todo público',
      'Apta para cualquier edad, sin contenido que afecte a los menores.', 0),
  'B': AgeRatingInfo('B', 'Para mayores de 12 años',
      'Puede incluir violencia leve, lenguaje moderado o escenas de tensión.', 1),
  'B15': AgeRatingInfo('B15', 'Para mayores de 15 años',
      'Puede incluir violencia, lenguaje fuerte o temas sexuales moderados.', 2),
  'C': AgeRatingInfo('C', 'Para mayores de 18 años',
      'Contenido para adultos: violencia, sexo o lenguaje explícitos.', 3),
  'D': AgeRatingInfo('D', 'Exclusiva para adultos',
      'Contenido explícito, pensado solo para adultos.', 3),
  // Estados Unidos — cine (MPA).
  'G': AgeRatingInfo('G', 'Público general',
      'Apta para todas las edades. No tiene nada que moleste a los niños.', 0),
  'PG': AgeRatingInfo('PG', 'Se sugiere guía de los padres',
      'Algún material podría no ser adecuado para niños pequeños.', 1),
  'PG-13': AgeRatingInfo('PG-13', 'Padres, ojo: no recomendada a menores de 13',
      'Puede incluir violencia, lenguaje o temas que no convienen a menores de 13 años.',
      2),
  'R': AgeRatingInfo('R', 'Restringida',
      'Los menores de 17 años deberían verla acompañados de un adulto.', 3),
  'NC-17': AgeRatingInfo('NC-17', 'Solo adultos',
      'No recomendada a menores de 18 años.', 3),
  // Estados Unidos — televisión.
  'TV-Y': AgeRatingInfo('TV-Y', 'Apta para todos los niños',
      'Programación creada para niños de todas las edades, incluso muy pequeños.', 0),
  'TV-Y7': AgeRatingInfo('TV-Y7', 'Dirigida a niños de 7 años en adelante',
      'Puede incluir fantasía o violencia ligera que los más pequeños no distinguen bien.',
      1),
  'TV-G': AgeRatingInfo('TV-G', 'Público general',
      'Apta para todas las edades.', 0),
  'TV-PG': AgeRatingInfo('TV-PG', 'Se sugiere guía de los padres',
      'Puede contener algo de violencia, lenguaje o situaciones que no convienen a los más pequeños.',
      1),
  'TV-14': AgeRatingInfo('TV-14', 'Mayores de 14 años',
      'Puede incluir violencia intensa, lenguaje fuerte o temas sexuales.', 2),
  'TV-MA': AgeRatingInfo('TV-MA', 'Solo para adultos',
      'Pensada para mayores de 17 años: violencia, sexo o lenguaje explícitos.', 3),
  'NR': AgeRatingInfo('NR', 'Sin clasificar',
      'Este título no tiene una clasificación oficial.', 1),
  'NOT RATED': AgeRatingInfo('NR', 'Sin clasificar',
      'Este título no tiene una clasificación oficial.', 1),
  // España y varios países que usan edades numéricas.
  'TP': AgeRatingInfo('TP', 'Todos los públicos',
      'Apta para todas las edades.', 0),
  'L': AgeRatingInfo('L', 'Libre para todos los públicos',
      'Apta para todas las edades.', 0),
};

/// Interpreta la clasificación guardada en el perfil. null si no hay ninguna.
AgeRatingInfo? ageRatingInfo(String? raw) {
  final c = (raw ?? '').trim();
  if (c.isEmpty) return null;
  final known = _scales[c.toUpperCase()];
  if (known != null) return known;
  // Edades numéricas: "12", "16+", "18"...
  final n = int.tryParse(c.replaceAll(RegExp(r'[^0-9]'), ''));
  if (n != null) {
    if (n == 0) return _scales['TP'];
    final tier = n <= 6 ? 0 : (n <= 12 ? 1 : (n <= 15 ? 2 : 3));
    return AgeRatingInfo(
        n >= 16 ? '$n' : '$n+',
        n >= 18 ? 'Solo para adultos' : 'Para mayores de $n años',
        n >= 18
            ? 'Contenido pensado únicamente para adultos.'
            : 'Recomendada para personas de $n años en adelante.',
        tier);
  }
  return AgeRatingInfo(c, 'Clasificación $c',
      'Clasificación de edades según el país de origen.', 1);
}

/// Sello pequeño y discreto con la clasificación de edades. Al tocarlo se
/// explica qué significa. No ocupa espacio si no hay clasificación.
class AgeRatingBadge extends StatelessWidget {
  const AgeRatingBadge({super.key, required this.certification, this.country});
  final String? certification, country;

  static Widget? maybe(String? certification, String? country) =>
      ageRatingInfo(certification) == null
          ? null
          : AgeRatingBadge(certification: certification, country: country);

  void _explain(BuildContext context, AgeRatingInfo info) {
    final place = _countries[(country ?? '').toUpperCase()] ?? country;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B1B1B),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _chip(info, 15, 10, 5),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Text(info.title,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700))),
                ]),
                const SizedBox(height: 14),
                Text(info.description,
                    style: const TextStyle(
                        fontSize: 15, height: 1.4, color: Colors.white70)),
                const SizedBox(height: 14),
                Text(
                    place == null || place.isEmpty
                        ? 'Fuente: TMDB'
                        : 'Clasificación de $place · Fuente: TMDB',
                    style:
                        const TextStyle(fontSize: 11.5, color: Colors.white38)),
              ]),
        ),
      ),
    );
  }

  static Widget _chip(AgeRatingInfo info, double size, double padH, double padV) =>
      Container(
        padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          color: info.color.withAlpha(30),
          border: Border.all(color: info.color.withAlpha(150), width: 0.9),
        ),
        child: Text(info.label,
            style: TextStyle(
                fontSize: size,
                height: 1.1,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: info.color)),
      );

  @override
  Widget build(BuildContext context) {
    final info = ageRatingInfo(certification);
    if (info == null) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: 'Clasificación ${info.label}. ${info.title}',
      child: Tooltip(
        message: info.title,
        child: InkWell(
            borderRadius: BorderRadius.circular(5),
            onTap: () => _explain(context, info),
            child: _chip(info, 11.5, 6, 2)),
      ),
    );
  }
}
