/// Implementación offline-first de [RecipeRepository].
///
/// **SRP:** une las piezas: lee y escribe en SQLite ([DatabaseHelper]) al
/// instante, sella cada cambio con el usuario y la hora, y delega la subida y
/// bajada en [SyncService] sin bloquear a la UI.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/recipe_category.dart';
import '../models/recipe_entry.dart';
import '../models/sync_state.dart';
import '../services/auth_repository.dart';
import '../services/sync_service.dart';
import 'database_helper.dart';
import 'recipe_repository.dart';

/// Repositorio de producción: SQLite como fuente de verdad + Supabase.
class LocalFirstRecipeRepository implements RecipeRepository {
  /// Crea el repositorio con sus colaboradores.
  LocalFirstRecipeRepository({
    required this._local,
    required this._sync,
    required this._auth,
  });

  final DatabaseHelper _local;
  final SyncService _sync;
  final AuthRepository _auth;

  @override
  String? get currentUserId => _auth.currentUserId;

  String get _requireUserId {
    final id = _auth.currentUserId;
    if (id == null) throw Exception('No hay una sesión iniciada.');
    return id;
  }

  /// Prepara la sesión de [userId]: reclama las recetas creadas antes de
  /// iniciar sesión, activa la escucha de conectividad y sincroniza.
  Future<void> activateSession(String userId) async {
    try {
      final claimed = await _local.claimAnonymousRecipes(userId);
      if (claimed > 0) {
        debugPrint('[Repository] $claimed recetas locales asignadas.');
      }
    } catch (e) {
      debugPrint('[Repository] claimAnonymousRecipes: $e');
    }
    _sync.reset();
    _sync.start(() => _auth.currentUserId);
    await _sync.syncAll(userId);
  }

  /// Limpia el estado de sincronización al cerrar sesión. Los datos locales
  /// se conservan (aislados por `user_id`) para no perder cambios pendientes.
  void deactivateSession() => _sync.reset();

  void _scheduleSync(String userId) {
    unawaited(_sync.refreshPendingCount(userId));
    unawaited(_sync.syncAll(userId));
  }

  // ---------------------------------------------------------------------------
  // Lecturas (solo SQLite)
  // ---------------------------------------------------------------------------

  @override
  Future<List<RecipeCategory>> getCategories() => _local.getCategories();

  @override
  Future<List<RecipeEntry>> getAllRecipes() =>
      _local.getRecipesByUser(_requireUserId);

  @override
  Future<List<RecipeEntry>> getRecipesByCategory(String categoryId) =>
      _local.getRecipesByUser(_requireUserId, categoryId: categoryId);

  @override
  Future<List<RecipeEntry>> getFavoriteRecipes() =>
      _local.getRecipesByUser(_requireUserId, favoritesOnly: true);

  // ---------------------------------------------------------------------------
  // Escrituras (SQLite inmediato + sync en segundo plano)
  // ---------------------------------------------------------------------------

  @override
  Future<RecipeEntry> saveRecipe(RecipeEntry recipe) async {
    final userId = _requireUserId;
    final existing = await _local.getRecipeById(recipe.id);
    if (existing != null && existing.userId != userId) {
      throw Exception('La receta pertenece a otro usuario.');
    }

    // Si la foto local cambió, la URL remota anterior ya no sirve: se borra
    // para que el próximo push suba la foto nueva.
    final imageChanged =
        recipe.imagePath != null && recipe.imagePath != existing?.imagePath;

    final stamped = recipe.copyWith(
      userId: userId,
      createdAt: existing?.createdAt ?? recipe.createdAt,
      updatedAt: DateTime.now().toUtc(),
      isDeleted: false,
      syncStatus: SyncStatus.pending,
      clearImageUrl: imageChanged,
    );
    await _local.saveRecipe(stamped);
    _scheduleSync(userId);
    // Se relee para devolverla con el nombre de categoría (JOIN).
    return await _local.getRecipeById(stamped.id) ?? stamped;
  }

  @override
  Future<RecipeEntry> toggleFavorite(RecipeEntry recipe) async {
    final userId = _requireUserId;
    // Se parte de la fila guardada para no pisar cambios más recientes.
    final current = await _local.getRecipeById(recipe.id) ?? recipe;
    final updated = current.copyWith(
      isFavorite: !current.isFavorite,
      updatedAt: DateTime.now().toUtc(),
      syncStatus: SyncStatus.pending,
    );
    await _local.saveRecipe(updated);
    _scheduleSync(userId);
    return updated;
  }

  @override
  Future<void> deleteRecipe(String id) async {
    final userId = _requireUserId;
    await _local.softDeleteRecipe(id, updatedAt: DateTime.now().toUtc());
    _scheduleSync(userId);
  }

  // ---------------------------------------------------------------------------
  // Sincronización
  // ---------------------------------------------------------------------------

  @override
  Future<void> syncAll() async {
    final userId = _auth.currentUserId;
    if (userId == null) return;
    await _sync.syncAll(userId);
  }

  @override
  ValueListenable<SyncState> get syncState => _sync.state;

  @override
  Stream<void> get remoteChanges => _sync.changes;
}
