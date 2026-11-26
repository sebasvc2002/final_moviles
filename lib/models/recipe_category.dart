/// Categoría de recetas (tabla `categories`).
///
/// Es un catálogo compartido y de solo lectura para la app: se siembra con
/// [kDefaultCategories] y se actualiza desde Supabase en cada sincronización.
library;

/// Una categoría a la que pertenece cada receta.
///
/// Se llama `RecipeCategory` (y no `Category`) para no chocar con la
/// anotación `Category` que exporta `package:flutter/foundation.dart`.
class RecipeCategory {
  /// Crea la categoría.
  const RecipeCategory({
    required this.id,
    required this.name,
    this.icon = '',
    this.sortOrder = 0,
  });

  /// UUID fijo, idéntico en todos los dispositivos y en el servidor.
  final String id;

  /// Nombre visible (por ejemplo, `"Postre"`).
  final String name;

  /// Clave del ícono (`breakfast`, `main`, `dessert`, `drink`…); la UI la
  /// traduce a un `IconData`.
  final String icon;

  /// Orden de aparición en el menú y en el formulario.
  final int sortOrder;

  /// Fila para SQLite o Supabase (mismas columnas en ambos).
  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'icon': icon,
    'sort_order': sortOrder,
  };

  /// Reconstruye la categoría desde una fila de SQLite o Supabase.
  factory RecipeCategory.fromMap(Map<String, dynamic> map) => RecipeCategory(
    id: map['id'] as String,
    name: map['name'] as String? ?? '',
    icon: map['icon'] as String? ?? '',
    sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
  );

  @override
  bool operator ==(Object other) => other is RecipeCategory && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Categorías iniciales. Los UUID deben coincidir con los de
/// `supabase/schema.sql`.
const List<RecipeCategory> kDefaultCategories = [
  RecipeCategory(
    id: 'c0000000-0000-4000-8000-000000000001',
    name: 'Desayuno',
    icon: 'breakfast',
    sortOrder: 1,
  ),
  RecipeCategory(
    id: 'c0000000-0000-4000-8000-000000000002',
    name: 'Plato Fuerte',
    icon: 'main',
    sortOrder: 2,
  ),
  RecipeCategory(
    id: 'c0000000-0000-4000-8000-000000000003',
    name: 'Postre',
    icon: 'dessert',
    sortOrder: 3,
  ),
  RecipeCategory(
    id: 'c0000000-0000-4000-8000-000000000004',
    name: 'Bebida',
    icon: 'drink',
    sortOrder: 4,
  ),
];

/// Id de la categoría para un [name] heredado; si no existe usa la primera.
String categoryIdForName(String? name) => kDefaultCategories
    .firstWhere((c) => c.name == name, orElse: () => kDefaultCategories.first)
    .id;
