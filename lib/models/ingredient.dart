/// Ingrediente de una receta (tabla `ingredients`).
library;

import 'package:uuid/uuid.dart';

/// Una línea de la lista de ingredientes de una receta.
class Ingredient {
  /// Crea el ingrediente.
  const Ingredient({
    required this.id,
    required this.recipeId,
    required this.position,
    required this.name,
  });

  /// UUID v4 generado en el cliente.
  final String id;

  /// Receta a la que pertenece.
  final String recipeId;

  /// Orden dentro de la receta (0, 1, 2…).
  final int position;

  /// Texto del ingrediente (por ejemplo, `"2 tazas de harina"`).
  final String name;

  /// Convierte texto con un ingrediente por línea en filas ordenadas,
  /// ignorando líneas vacías.
  static List<Ingredient> fromLines(String recipeId, String text) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    return [
      for (final (i, line) in lines.indexed)
        Ingredient(
          id: const Uuid().v4(),
          recipeId: recipeId,
          position: i,
          name: line,
        ),
    ];
  }

  /// Fila de SQLite (sin `user_id`; la propiedad la da la receta).
  Map<String, Object?> toMap() => {
    'id': id,
    'recipe_id': recipeId,
    'position': position,
    'name': name,
  };

  /// Elemento para la función remota `upsert_recipe` (el servidor asigna
  /// `recipe_id` y `user_id`).
  Map<String, Object?> toSupabaseMap() => {
    'id': id,
    'position': position,
    'name': name,
  };

  /// Reconstruye el ingrediente desde una fila de SQLite o Supabase.
  factory Ingredient.fromMap(Map<String, dynamic> map) => Ingredient(
    id: map['id'] as String,
    recipeId: map['recipe_id'] as String,
    position: (map['position'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
  );
}
