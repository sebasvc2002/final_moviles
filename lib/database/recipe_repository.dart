/// Contrato de persistencia de recetas que usa la UI.
///
/// **DIP / ISP:** las pantallas dependen de esta abstracción y no de SQLite
/// ni de Supabase. Así se puede sustituir la implementación (por ejemplo, un
/// repositorio en memoria para pruebas) sin modificar la UI.
library;

import 'package:flutter/foundation.dart';

import '../models/recipe_category.dart';
import '../models/recipe_entry.dart';
import '../models/sync_state.dart';

/// Operaciones de lectura y escritura sobre las recetas del usuario actual.
///
/// Las lecturas y escrituras son locales e inmediatas; la sincronización
/// con el servidor ocurre en segundo plano. Toda implementación debe lanzar
/// una [Exception] con un mensaje legible si la operación falla, para que la
/// UI pueda mostrarlo sin cerrar la app.
abstract interface class RecipeRepository {
  /// Id del usuario con sesión iniciada, o `null`.
  String? get currentUserId;

  /// Devuelve las categorías disponibles, en orden de presentación.
  Future<List<RecipeCategory>> getCategories();

  /// Devuelve todas las recetas, de la más reciente a la más antigua.
  Future<List<RecipeEntry>> getAllRecipes();

  /// Devuelve las recetas de la categoría [categoryId], de la más reciente a
  /// la más antigua.
  Future<List<RecipeEntry>> getRecipesByCategory(String categoryId);

  /// Devuelve solo las recetas marcadas como favoritas.
  Future<List<RecipeEntry>> getFavoriteRecipes();

  /// Crea o actualiza [recipe] junto con sus ingredientes y devuelve la
  /// versión guardada (con `userId`, `updatedAt`, nombre de categoría y
  /// estado de sincronización asignados).
  Future<RecipeEntry> saveRecipe(RecipeEntry recipe);

  /// Invierte el favorito de [recipe] y devuelve la versión guardada.
  Future<RecipeEntry> toggleFavorite(RecipeEntry recipe);

  /// Elimina (lógicamente) la receta [id].
  Future<void> deleteRecipe(String id);

  /// Sincroniza con el servidor. Nunca lanza: el resultado se refleja en
  /// [syncState].
  Future<void> syncAll();

  /// Estado de sincronización observable.
  ValueListenable<SyncState> get syncState;

  /// Emite cuando llegaron cambios del servidor y conviene recargar.
  Stream<void> get remoteChanges;
}
