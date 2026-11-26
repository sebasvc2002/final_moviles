/// Única puerta de entrada a Supabase: Auth, PostgreSQL y Storage.
///
/// **SRP / DIP:** traduce las operaciones de [AuthRepository] y
/// [RemoteRecipeStore] a llamadas de `supabase_flutter`. Ninguna pantalla
/// importa este archivo; solo la raíz de composición (`main.dart`).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../models/recipe_category.dart';
import '../models/recipe_entry.dart';
import 'auth_repository.dart';

/// Cambios remotos recibidos en un pull.
class RemoteDelta {
  /// Crea el lote.
  const RemoteDelta({required this.recipes, required this.cursor});

  /// Recetas modificadas en el servidor desde el último cursor.
  final List<RecipeEntry> recipes;

  /// Mayor `server_updated_at` visto (hora del servidor); se guarda como
  /// nuevo cursor. `null` si no llegó nada.
  final DateTime? cursor;
}

/// Operaciones remotas que necesita el motor de sincronización.
abstract interface class RemoteRecipeStore {
  /// Sube la foto local de [recipe] a Storage y devuelve su URL pública, o
  /// `null` si el archivo local ya no existe.
  Future<String?> uploadRecipeImage(RecipeEntry recipe);

  /// Inserta o actualiza [recipe] y reemplaza sus ingredientes en una sola
  /// transacción remota. Devuelve `false` si el servidor ya tenía una
  /// versión más reciente (Last-Write-Wins) y no se aplicó nada.
  Future<bool> upsertRecipe(RecipeEntry recipe);

  /// Catálogo completo de categorías.
  Future<List<RecipeCategory>> fetchCategories();

  /// Recetas de [userId] (con sus ingredientes) cambiadas en el servidor
  /// después de [since] (todas si es `null`), incluidas las borradas
  /// lógicamente.
  Future<RemoteDelta> fetchUpdatedRecipes(String userId, DateTime? since);
}

/// Implementación con `supabase_flutter` de [AuthRepository] y
/// [RemoteRecipeStore].
class SupabaseService implements AuthRepository, RemoteRecipeStore {
  /// Crea el servicio. [client] permite inyectar otro cliente; por defecto
  /// usa `Supabase.instance.client` (requiere `Supabase.initialize`).
  SupabaseService({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  static const int _pageSize = 500;

  GoTrueClient get _auth => _client.auth;

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  @override
  String? get currentUserId => _auth.currentUser?.id;

  @override
  String? get currentUserEmail => _auth.currentUser?.email;

  @override
  Stream<String?> get userIdChanges =>
      _auth.onAuthStateChange.map((s) => s.session?.user.id).distinct();

  @override
  Future<void> signIn(String email, String password) async {
    try {
      await _auth.signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      throw Exception(_authMessage(e));
    } catch (e) {
      debugPrint('[SupabaseService] signIn falló: $e');
      throw Exception('No se pudo iniciar sesión. Revisa tu conexión.');
    }
  }

  @override
  Future<SignUpResult> signUp(String email, String password) async {
    try {
      final res = await _auth.signUp(email: email, password: password);
      return res.session != null
          ? SignUpResult.signedIn
          : SignUpResult.confirmationRequired;
    } on AuthException catch (e) {
      throw Exception(_authMessage(e));
    } catch (e) {
      debugPrint('[SupabaseService] signUp falló: $e');
      throw Exception('No se pudo crear la cuenta. Revisa tu conexión.');
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _auth.signOut();
    } catch (e) {
      // Sin red, signOut puede fallar al revocar el token; la sesión local
      // igualmente se borra, así que solo se registra.
      debugPrint('[SupabaseService] signOut: $e');
    }
  }

  static String _authMessage(AuthException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('invalid login')) {
      return 'Correo o contraseña incorrectos.';
    }
    if (msg.contains('already registered')) {
      return 'Ya existe una cuenta con ese correo.';
    }
    if (msg.contains('email not confirmed')) {
      return 'Confirma tu correo antes de iniciar sesión.';
    }
    return e.message;
  }

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------

  @override
  Future<String?> uploadRecipeImage(RecipeEntry recipe) async {
    final localPath = recipe.imagePath;
    if (localPath == null) return null;
    final file = File(localPath);
    if (!await file.exists()) return null;

    final objectPath = '${recipe.userId}/${recipe.id}.jpg';
    final bucket = _client.storage.from(SupabaseConfig.imagesBucket);
    await bucket.upload(
      objectPath,
      file,
      fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'),
    );
    // La ruta es fija por receta; el parámetro `v` evita que la CDN o la
    // caché de imágenes muestren la foto anterior tras reemplazarla.
    final publicUrl = bucket.getPublicUrl(objectPath);
    return '$publicUrl?v=${recipe.updatedAt.millisecondsSinceEpoch}';
  }

  // ---------------------------------------------------------------------------
  // PostgreSQL
  // ---------------------------------------------------------------------------

  @override
  Future<bool> upsertRecipe(RecipeEntry recipe) async {
    final applied = await _client.rpc<dynamic>(
      'upsert_recipe',
      params: {
        'p_recipe': recipe.toSupabaseMap(),
        'p_ingredients': [
          for (final ingredient in recipe.ingredients)
            ingredient.toSupabaseMap(),
        ],
      },
    );
    return applied != false;
  }

  @override
  Future<List<RecipeCategory>> fetchCategories() async {
    final rows = await _client
        .from(SupabaseConfig.categoriesTable)
        .select()
        .order('sort_order', ascending: true);
    return rows.map(RecipeCategory.fromMap).toList();
  }

  @override
  Future<RemoteDelta> fetchUpdatedRecipes(
    String userId,
    DateTime? since,
  ) async {
    final recipes = <RecipeEntry>[];
    DateTime? cursor;
    var from = 0;
    while (true) {
      var query = _client
          .from(SupabaseConfig.recipesTable)
          // Embebe los ingredientes gracias a la FK ingredients.recipe_id.
          .select('*, ingredients(*)')
          .eq('user_id', userId);
      if (since != null) {
        query = query.gt('server_updated_at', since.toUtc().toIso8601String());
      }
      final rows = await query
          .order('server_updated_at', ascending: true)
          .order('id', ascending: true)
          .range(from, from + _pageSize - 1);

      for (final row in rows) {
        recipes.add(RecipeEntry.fromSupabaseMap(row));
        final serverTime = DateTime.tryParse(
          row['server_updated_at'] as String? ?? '',
        )?.toUtc();
        if (serverTime != null &&
            (cursor == null || serverTime.isAfter(cursor))) {
          cursor = serverTime;
        }
      }
      if (rows.length < _pageSize) break;
      from += _pageSize;
    }
    return RemoteDelta(recipes: recipes, cursor: cursor);
  }
}
