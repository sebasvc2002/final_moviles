/// Modelo de dominio de la app.
///
/// **SRP:** describe una receta (con su categoría y sus ingredientes) y sabe
/// convertirse a/desde filas de SQLite o de Supabase. No accede a la base de
/// datos, a la red ni a la UI.
library;

import 'package:uuid/uuid.dart';

import 'ingredient.dart';

/// Estado de sincronización local de una receta (solo existe en SQLite).
enum SyncStatus {
  /// Hay cambios locales que todavía no se suben a Supabase.
  pending,

  /// La copia local coincide con la última versión enviada/recibida.
  synced;

  /// Convierte el texto guardado en SQLite; cualquier valor desconocido se
  /// trata como `pending` para no perder cambios.
  static SyncStatus parse(String? value) =>
      value == 'synced' ? SyncStatus.synced : SyncStatus.pending;
}

/// Representa una receta: una fila de `recipes` más sus filas de
/// `ingredients` y el nombre de su fila en `categories`.
///
/// Es inmutable: los cambios se hacen creando una copia con [copyWith].
class RecipeEntry {
  /// Identificador UUID v4 generado en el cliente (ver [newId]), de modo que
  /// las recetas creadas sin conexión nunca colisionan entre dispositivos.
  final String id;

  /// Id del usuario de Supabase dueño de la receta. Cadena vacía para
  /// recetas heredadas creadas antes de iniciar sesión.
  final String userId;

  /// Nombre del platillo.
  final String title;

  /// Clave foránea a `categories.id`.
  final String categoryId;

  /// Nombre de la categoría (viene del JOIN con `categories`; no se guarda
  /// en la tabla `recipes`).
  final String categoryName;

  /// Tiempo de preparación en texto libre (por ejemplo, `"30 min"`).
  final String prepTime;

  /// Ingredientes en orden (filas de la tabla `ingredients`).
  final List<Ingredient> ingredients;

  /// Pasos de preparación, uno por línea.
  final String instructions;

  /// Ruta absoluta de la foto en este dispositivo (solo local); `null` si no
  /// hay copia local.
  final String? imagePath;

  /// URL pública de la foto en Supabase Storage; `null` si aún no se sube.
  final String? imageUrl;

  /// Si la receta está marcada como favorita.
  final bool isFavorite;

  /// Fecha de creación (UTC).
  final DateTime createdAt;

  /// Última modificación (UTC). Decide los conflictos (Last-Write-Wins).
  final DateTime updatedAt;

  /// Marca de borrado lógico: el registro se conserva para propagar el
  /// borrado a otros dispositivos.
  final bool isDeleted;

  /// Estado de sincronización (solo local; no se envía a Supabase).
  final SyncStatus syncStatus;

  /// Crea una receta.
  const RecipeEntry({
    required this.id,
    required this.userId,
    required this.title,
    required this.categoryId,
    this.categoryName = '',
    required this.prepTime,
    this.ingredients = const [],
    required this.instructions,
    this.imagePath,
    this.imageUrl,
    this.isFavorite = false,
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
    this.syncStatus = SyncStatus.pending,
  });

  /// Genera un nuevo identificador UUID v4.
  static String newId() => const Uuid().v4();

  /// Alias conservado por compatibilidad con la UI existente.
  bool get favorite => isFavorite;

  /// Indica si la receta tiene cambios locales sin subir.
  bool get isPending => syncStatus == SyncStatus.pending;

  /// Tag único compartido entre la lista y el detalle para la animación Hero.
  String get heroTag => 'recipe-hero-$id';

  /// Nombres de los ingredientes, en orden.
  List<String> get ingredientList => [
    for (final ingredient in ([
      ...ingredients,
    ]..sort((a, b) => a.position.compareTo(b.position))))
      ingredient.name,
  ];

  /// Ingredientes como texto, uno por línea (para el formulario).
  String get ingredientsText => ingredientList.join('\n');

  /// Pasos de preparación como lista, sin líneas vacías.
  List<String> get instructionSteps => instructions
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  static DateTime _parseDate(Object? value) {
    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toUtc();
    }
    return DateTime.now().toUtc();
  }

  static bool _parseBool(Object? value) =>
      value == true || value == 1 || value == 'true';

  // ---------------------------------------------------------------------------
  // SQLite
  // ---------------------------------------------------------------------------

  /// Fila de la tabla local `recipes` (sin ingredientes ni nombre de
  /// categoría, que viven en sus propias tablas).
  Map<String, Object?> toMap() {
    return {
      'id': id,
      'user_id': userId,
      'title': title,
      'category_id': categoryId,
      'prep_time': prepTime,
      'instructions': instructions,
      'image_path': imagePath,
      'image_url': imageUrl,
      'is_favorite': isFavorite ? 1 : 0,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'is_deleted': isDeleted ? 1 : 0,
      'sync_status': syncStatus.name,
    };
  }

  /// Reconstruye una receta desde una fila de SQLite (opcionalmente con la
  /// columna `category_name` del JOIN) y sus [ingredients].
  factory RecipeEntry.fromMap(
    Map<String, Object?> map, {
    List<Ingredient> ingredients = const [],
  }) {
    final imagePath = map['image_path'] as String?;
    return RecipeEntry(
      id: map['id'] as String? ?? newId(),
      userId: map['user_id'] as String? ?? '',
      title: map['title'] as String? ?? '',
      categoryId: map['category_id'] as String? ?? '',
      categoryName: map['category_name'] as String? ?? '',
      prepTime: map['prep_time'] as String? ?? '',
      ingredients: ingredients,
      instructions: map['instructions'] as String? ?? '',
      imagePath: (imagePath == null || imagePath.isEmpty) ? null : imagePath,
      imageUrl: map['image_url'] as String?,
      isFavorite: _parseBool(map['is_favorite']),
      createdAt: _parseDate(map['created_at']),
      updatedAt: _parseDate(map['updated_at']),
      isDeleted: _parseBool(map['is_deleted']),
      syncStatus: SyncStatus.parse(map['sync_status'] as String?),
    );
  }

  // ---------------------------------------------------------------------------
  // Supabase (PostgreSQL)
  // ---------------------------------------------------------------------------

  /// Fila para la tabla remota `public.recipes`. Excluye los campos solo
  /// locales (`image_path`, `sync_status`); los ingredientes se envían
  /// aparte con [Ingredient.toSupabaseMap].
  Map<String, Object?> toSupabaseMap() {
    return {
      'id': id,
      'user_id': userId,
      'title': title,
      'category_id': categoryId,
      'prep_time': prepTime,
      'instructions': instructions,
      'image_url': imageUrl,
      'is_favorite': isFavorite,
      'created_at': createdAt.toUtc().toIso8601String(),
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'is_deleted': isDeleted,
    };
  }

  /// Reconstruye una receta recibida de Supabase con sus ingredientes
  /// embebidos (`select('*, ingredients(*)')`). Se marca como `synced` y sin
  /// ruta local; el motor de sync conserva la ruta local si ya existía.
  factory RecipeEntry.fromSupabaseMap(Map<String, dynamic> map) {
    final rawIngredients = map['ingredients'];
    final ingredients = rawIngredients is List
        ? [
            for (final row in rawIngredients)
              Ingredient.fromMap(Map<String, dynamic>.from(row as Map)),
          ]
        : const <Ingredient>[];
    return RecipeEntry(
      id: map['id'] as String,
      userId: map['user_id'] as String,
      title: map['title'] as String? ?? '',
      categoryId: map['category_id'] as String? ?? '',
      prepTime: map['prep_time'] as String? ?? '',
      ingredients: ingredients,
      instructions: map['instructions'] as String? ?? '',
      imageUrl: map['image_url'] as String?,
      isFavorite: _parseBool(map['is_favorite']),
      createdAt: _parseDate(map['created_at'] ?? map['updated_at']),
      updatedAt: _parseDate(map['updated_at']),
      isDeleted: _parseBool(map['is_deleted']),
      syncStatus: SyncStatus.synced,
    );
  }

  /// Devuelve una copia con los campos indicados reemplazados. Para borrar
  /// [imagePath] o [imageUrl] usa [clearImagePath] / [clearImageUrl].
  RecipeEntry copyWith({
    String? id,
    String? userId,
    String? title,
    String? categoryId,
    String? categoryName,
    String? prepTime,
    List<Ingredient>? ingredients,
    String? instructions,
    String? imagePath,
    bool clearImagePath = false,
    String? imageUrl,
    bool clearImageUrl = false,
    bool? isFavorite,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDeleted,
    SyncStatus? syncStatus,
  }) {
    return RecipeEntry(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      title: title ?? this.title,
      categoryId: categoryId ?? this.categoryId,
      categoryName: categoryName ?? this.categoryName,
      prepTime: prepTime ?? this.prepTime,
      ingredients: ingredients ?? this.ingredients,
      instructions: instructions ?? this.instructions,
      imagePath: clearImagePath ? null : (imagePath ?? this.imagePath),
      imageUrl: clearImageUrl ? null : (imageUrl ?? this.imageUrl),
      isFavorite: isFavorite ?? this.isFavorite,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}
