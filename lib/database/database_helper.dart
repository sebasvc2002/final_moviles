/// Acceso local a SQLite (sqflite): la fuente de verdad de la UI.
///
/// **SRP:** su única responsabilidad es traducir operaciones a consultas
/// sobre las tablas `categories`, `recipes`, `ingredients` y
/// `sync_metadata`. No conoce la UI, la red ni Supabase; la coordinación
/// vive en `LocalFirstRecipeRepository`.
///
/// Esquema (v4):
/// ```text
/// categories 1 ──< recipes 1 ──< ingredients
/// ```
library;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/ingredient.dart';
import '../models/recipe_category.dart';
import '../models/recipe_entry.dart';

/// Acceso Singleton a la base de datos local `cookbook.db`.
///
/// Cada operación está envuelta en try-catch: el error se registra en consola
/// y se relanza como una [Exception] controlada para que la UI lo muestre sin
/// cerrar la aplicación.
class DatabaseHelper {
  DatabaseHelper._internal();

  /// Instancia única compartida por toda la app.
  static final DatabaseHelper instance = DatabaseHelper._internal();

  static const String _dbName = 'cookbook.db';

  /// Historial de versiones:
  /// - v2: se dejó de guardar la ubicación (columnas latitude/longitude).
  /// - v3: ids UUID, `user_id`, borrado lógico, `updated_at`, `image_url`,
  ///   `sync_status` y tabla `sync_metadata` (sincronización con Supabase).
  /// - v4: esquema normalizado en tres tablas: `categories`, `recipes`
  ///   (con `category_id`) e `ingredients` (una fila por ingrediente).
  static const int _dbVersion = 4;

  /// Tabla de categorías.
  static const String tableCategories = 'categories';

  /// Tabla de recetas.
  static const String tableRecipes = 'recipes';

  /// Tabla de ingredientes.
  static const String tableIngredients = 'ingredients';

  /// Tabla con el cursor de sincronización por usuario.
  static const String tableSyncMetadata = 'sync_metadata';

  /// `user_id` de las recetas creadas antes de existir el inicio de sesión;
  /// se reasignan con [claimAnonymousRecipes].
  static const String anonymousUserId = '';

  Database? _database;

  /// Conexión abierta de forma perezosa la primera vez que se necesita.
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// Cierra la conexión (la siguiente operación la vuelve a abrir). Útil en
  /// pruebas para forzar una migración desde un archivo preparado.
  @visibleForTesting
  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  Future<Database> _initDatabase() async {
    try {
      final dbPath = await getDatabasesPath();
      final path = join(dbPath, _dbName);
      return await openDatabase(
        path,
        version: _dbVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    } catch (e) {
      debugPrint('[DatabaseHelper] Error al abrir la base de datos: $e');
      throw Exception('Error al acceder a la base de datos: $e');
    }
  }

  /// SQLite no aplica las claves foráneas a menos que se active por
  /// conexión (y fuera de una transacción).
  Future<void> _onConfigure(Database db) =>
      db.execute('PRAGMA foreign_keys = ON');

  /// Crea el esquema actual en una instalación nueva.
  Future<void> _onCreate(Database db, int version) => _createSchema(db);

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $tableCategories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        icon TEXT NOT NULL DEFAULT '',
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableRecipes (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        title TEXT NOT NULL,
        category_id TEXT NOT NULL REFERENCES $tableCategories (id),
        prep_time TEXT NOT NULL DEFAULT '',
        instructions TEXT NOT NULL,
        image_path TEXT,
        image_url TEXT,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        sync_status TEXT NOT NULL DEFAULT 'pending'
      )
    ''');
    await db.execute('''
      CREATE TABLE $tableIngredients (
        id TEXT PRIMARY KEY,
        recipe_id TEXT NOT NULL
          REFERENCES $tableRecipes (id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        name TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_recipes_user_updated '
      'ON $tableRecipes (user_id, is_deleted, updated_at)',
    );
    await db.execute(
      'CREATE INDEX idx_recipes_category ON $tableRecipes (category_id)',
    );
    await db.execute(
      'CREATE INDEX idx_ingredients_recipe '
      'ON $tableIngredients (recipe_id, position)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableSyncMetadata (
        user_id TEXT PRIMARY KEY,
        last_synced_at TEXT NOT NULL
      )
    ''');

    final batch = db.batch();
    for (final category in kDefaultCategories) {
      batch.insert(
        tableCategories,
        category.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Migra bases creadas por versiones anteriores a v4.
  ///
  /// La tabla `recipes` antigua se renombra, se crea el esquema nuevo y cada
  /// fila se copia: su texto de categoría se convierte en `category_id` y su
  /// texto de ingredientes en filas de `ingredients`.
  /// - Desde v1/v2 (ids enteros, columnas camelCase) cada receta recibe un
  ///   UUID nuevo y `user_id` vacío (se reasigna al primer inicio de sesión).
  /// - Desde v3 se conservan id, usuario y estado de sincronización.
  ///
  /// Todo ocurre dentro de la transacción de `onUpgrade`: si algo falla no
  /// se pierde nada.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion >= 4) return;
    final isLegacy = oldVersion < 3;

    // El índice de v3 se iría con la tabla renombrada y su nombre chocaría
    // con el del esquema nuevo.
    await db.execute('DROP INDEX IF EXISTS idx_recipes_user_updated');
    await db.execute('ALTER TABLE $tableRecipes RENAME TO recipes_legacy');
    await _createSchema(db);

    final legacyRows = await db.query('recipes_legacy');
    final batch = db.batch();
    for (final row in legacyRows) {
      final entry = isLegacy ? _fromV2Row(row) : _fromV3Row(row);
      batch.insert(tableRecipes, entry.toMap());
      for (final ingredient in entry.ingredients) {
        batch.insert(tableIngredients, ingredient.toMap());
      }
    }
    await batch.commit(noResult: true);
    await db.execute('DROP TABLE recipes_legacy');
    debugPrint(
      '[DatabaseHelper] Migradas ${legacyRows.length} recetas de '
      'v$oldVersion a v$newVersion.',
    );
  }

  /// Convierte una fila de v1/v2 (camelCase, id entero).
  static RecipeEntry _fromV2Row(Map<String, Object?> row) {
    final id = RecipeEntry.newId();
    final createdAt =
        DateTime.tryParse(row['createdAt'] as String? ?? '')?.toUtc() ??
        DateTime.now().toUtc();
    final imagePath = row['imagePath'] as String?;
    return RecipeEntry(
      id: id,
      userId: anonymousUserId,
      title: row['title'] as String? ?? '',
      categoryId: categoryIdForName(row['category'] as String?),
      prepTime: row['prepTime'] as String? ?? '',
      ingredients: Ingredient.fromLines(
        id,
        row['ingredients'] as String? ?? '',
      ),
      instructions: row['instructions'] as String? ?? '',
      imagePath: (imagePath == null || imagePath.isEmpty) ? null : imagePath,
      isFavorite: row['isFavorite'] == 1,
      createdAt: createdAt,
      updatedAt: createdAt,
    );
  }

  /// Convierte una fila de v3 (snake_case, texto de categoría e
  /// ingredientes en la misma tabla).
  static RecipeEntry _fromV3Row(Map<String, Object?> row) {
    final base = RecipeEntry.fromMap({
      ...row,
      'category_id': categoryIdForName(row['category'] as String?),
    });
    return base.copyWith(
      ingredients: Ingredient.fromLines(
        base.id,
        row['ingredients'] as String? ?? '',
      ),
    );
  }

  Future<T> _guard<T>(String op, Future<T> Function(Database db) body) async {
    try {
      return await body(await database);
    } catch (e) {
      debugPrint('[DatabaseHelper] $op falló: $e');
      throw Exception('Error al acceder a la base de datos: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Categorías
  // ---------------------------------------------------------------------------

  /// Todas las categorías, en su orden de presentación.
  Future<List<RecipeCategory>> getCategories() {
    return _guard('getCategories', (db) async {
      final rows = await db.query(
        tableCategories,
        orderBy: 'sort_order ASC, name ASC',
      );
      return rows.map(RecipeCategory.fromMap).toList();
    });
  }

  /// Inserta o actualiza [categories] (catálogo recibido del servidor).
  Future<void> upsertCategories(List<RecipeCategory> categories) {
    return _guard('upsertCategories', (db) async {
      await db.transaction((txn) async {
        for (final category in categories) {
          final count = await txn.update(
            tableCategories,
            category.toMap(),
            where: 'id = ?',
            whereArgs: [category.id],
          );
          if (count == 0) await txn.insert(tableCategories, category.toMap());
        }
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Lectura de recetas (JOIN con categorías + ingredientes)
  // ---------------------------------------------------------------------------

  static const String _recipeSelect =
      'SELECT r.*, c.name AS category_name FROM $tableRecipes r '
      'LEFT JOIN $tableCategories c ON c.id = r.category_id';

  /// Ejecuta una consulta sobre `recipes r` con [where] y carga los
  /// ingredientes de todas las recetas resultantes en una sola consulta.
  static Future<List<RecipeEntry>> _queryRecipes(
    DatabaseExecutor db,
    String where,
    List<Object?> args, {
    String orderBy = 'r.created_at DESC',
  }) async {
    final rows = await db.rawQuery(
      '$_recipeSelect WHERE $where ORDER BY $orderBy',
      args,
    );
    if (rows.isEmpty) return const [];

    final ingredientRows = await db.rawQuery(
      'SELECT i.* FROM $tableIngredients i '
      'JOIN $tableRecipes r ON r.id = i.recipe_id '
      'WHERE $where ORDER BY i.recipe_id, i.position',
      args,
    );
    final byRecipe = <String, List<Ingredient>>{};
    for (final row in ingredientRows) {
      final ingredient = Ingredient.fromMap(row);
      (byRecipe[ingredient.recipeId] ??= []).add(ingredient);
    }

    return [
      for (final row in rows)
        RecipeEntry.fromMap(row, ingredients: byRecipe[row['id']] ?? const []),
    ];
  }

  /// Recetas visibles de [userId], de la más reciente a la más antigua.
  /// Opcionalmente filtra por [categoryId] o solo favoritas.
  Future<List<RecipeEntry>> getRecipesByUser(
    String userId, {
    String? categoryId,
    bool favoritesOnly = false,
  }) {
    return _guard('getRecipesByUser', (db) {
      final where = StringBuffer('r.user_id = ? AND r.is_deleted = 0');
      final args = <Object?>[userId];
      if (categoryId != null) {
        where.write(' AND r.category_id = ?');
        args.add(categoryId);
      }
      if (favoritesOnly) where.write(' AND r.is_favorite = 1');
      return _queryRecipes(db, where.toString(), args);
    });
  }

  /// Receta [id] (incluidas las borradas lógicamente) o `null`.
  Future<RecipeEntry?> getRecipeById(String id) {
    return _guard('getRecipeById', (db) async {
      final result = await _queryRecipes(db, 'r.id = ?', [id]);
      return result.isEmpty ? null : result.first;
    });
  }

  /// Recetas de [userId] con cambios sin subir (incluye borrados lógicos).
  Future<List<RecipeEntry>> getPendingRecipes(String userId) {
    return _guard(
      'getPendingRecipes',
      (db) => _queryRecipes(db, 'r.user_id = ? AND r.sync_status = ?', [
        userId,
        SyncStatus.pending.name,
      ], orderBy: 'r.updated_at ASC'),
    );
  }

  /// Número de recetas de [userId] pendientes de subir.
  Future<int> countPending(String userId) {
    return _guard('countPending', (db) async {
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM $tableRecipes '
        'WHERE user_id = ? AND sync_status = ?',
        [userId, SyncStatus.pending.name],
      );
      return Sqflite.firstIntValue(result) ?? 0;
    });
  }

  // ---------------------------------------------------------------------------
  // Escritura
  // ---------------------------------------------------------------------------

  /// Guarda [entry] y reemplaza sus ingredientes, todo en una transacción.
  ///
  /// Usa UPDATE y, si no existía, INSERT (en lugar de `INSERT OR REPLACE`,
  /// que borraría la fila y con ella, en cascada, sus ingredientes).
  Future<void> saveRecipe(RecipeEntry entry) {
    return _guard('saveRecipe', (db) async {
      await db.transaction((txn) async {
        final row = entry.toMap();
        final count = await txn.update(
          tableRecipes,
          row,
          where: 'id = ?',
          whereArgs: [entry.id],
        );
        if (count == 0) await txn.insert(tableRecipes, row);

        await txn.delete(
          tableIngredients,
          where: 'recipe_id = ?',
          whereArgs: [entry.id],
        );
        for (final (i, ingredient) in entry.ingredients.indexed) {
          // Se fuerza la receta y una posición consecutiva por seguridad.
          await txn.insert(tableIngredients, {
            ...ingredient.toMap(),
            'recipe_id': entry.id,
            'position': i,
          });
        }
      });
    });
  }

  /// Borrado lógico: marca la receta como eliminada y pendiente de subir.
  Future<void> softDeleteRecipe(String id, {DateTime? updatedAt}) {
    return _guard('softDeleteRecipe', (db) async {
      await db.update(
        tableRecipes,
        {
          'is_deleted': 1,
          'sync_status': SyncStatus.pending.name,
          'updated_at': (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  /// Marca la receta [id] como sincronizada y guarda [imageUrl] si se subió.
  ///
  /// Solo actúa si la fila sigue en la versión [pushedUpdatedAt]: si el
  /// usuario la editó mientras se subía, se queda `pending` para el próximo
  /// ciclo. Devuelve `true` si se marcó.
  Future<bool> markAsSynced(
    String id, {
    required DateTime pushedUpdatedAt,
    String? imageUrl,
  }) {
    return _guard('markAsSynced', (db) async {
      final values = <String, Object?>{'sync_status': SyncStatus.synced.name};
      if (imageUrl != null) values['image_url'] = imageUrl;
      final count = await db.update(
        tableRecipes,
        values,
        where: 'id = ? AND updated_at = ?',
        whereArgs: [id, pushedUpdatedAt.toUtc().toIso8601String()],
      );
      return count > 0;
    });
  }

  /// Reasigna a [userId] las recetas heredadas (creadas antes del inicio de
  /// sesión) y las deja pendientes de subir. Devuelve cuántas se reclamaron.
  Future<int> claimAnonymousRecipes(String userId) {
    return _guard('claimAnonymousRecipes', (db) async {
      return db.update(
        tableRecipes,
        {
          'user_id': userId,
          'sync_status': SyncStatus.pending.name,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'user_id = ?',
        whereArgs: [anonymousUserId],
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Metadatos de sincronización
  // ---------------------------------------------------------------------------

  /// Marca de tiempo (UTC) del último pull exitoso de [userId], o `null`.
  Future<DateTime?> getLastSyncTime(String userId) {
    return _guard('getLastSyncTime', (db) async {
      final rows = await db.query(
        tableSyncMetadata,
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return DateTime.tryParse(rows.first['last_synced_at'] as String)?.toUtc();
    });
  }

  /// Guarda el cursor de sincronización de [userId].
  Future<void> setLastSyncTime(String userId, DateTime time) {
    return _guard('setLastSyncTime', (db) async {
      await db.insert(tableSyncMetadata, {
        'user_id': userId,
        'last_synced_at': time.toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }
}
