import 'package:flutter_test/flutter_test.dart';
import 'package:m02_proyecto1/database/database_helper.dart';
import 'package:m02_proyecto1/models/ingredient.dart';
import 'package:m02_proyecto1/models/recipe_category.dart';
import 'package:m02_proyecto1/models/recipe_entry.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Crea `cookbook.db` con el esquema v2 (ids enteros, columnas camelCase).
Future<void> _createV2Database(String path) async {
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 2,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE recipes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            category TEXT NOT NULL,
            prepTime TEXT NOT NULL,
            ingredients TEXT NOT NULL,
            instructions TEXT NOT NULL,
            imagePath TEXT NOT NULL,
            isFavorite INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            latitude REAL,
            longitude REAL
          )
        ''');
        await db.insert('recipes', {
          'title': 'Chilaquiles',
          'category': 'Desayuno',
          'prepTime': '20 min',
          'ingredients': 'Totopos\n\nSalsa verde',
          'instructions': 'Freír',
          'imagePath': '',
          'isFavorite': 1,
          'createdAt': '2026-11-12T10:00:00.000',
        });
        await db.insert('recipes', {
          'title': 'Flan',
          'category': 'Postre',
          'prepTime': '1 h',
          'ingredients': 'Huevo',
          'instructions': 'Hornear',
          'imagePath': '/docs/flan.jpg',
          'isFavorite': 0,
          'createdAt': '2026-11-13T10:00:00.000',
        });
      },
    ),
  );
  await db.close();
}

/// Crea `cookbook.db` con el esquema v3 (una sola tabla con texto de
/// categoría e ingredientes) y una receta ya sincronizada.
Future<void> _createV3Database(String path) async {
  final db = await databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 3,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE recipes (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            title TEXT NOT NULL,
            category TEXT NOT NULL,
            prep_time TEXT NOT NULL DEFAULT '',
            ingredients TEXT NOT NULL,
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
        await db.execute(
          'CREATE INDEX idx_recipes_user_updated '
          'ON recipes (user_id, is_deleted, updated_at)',
        );
        await db.execute('''
          CREATE TABLE sync_metadata (
            user_id TEXT PRIMARY KEY,
            last_synced_at TEXT NOT NULL
          )
        ''');
        await db.insert('recipes', {
          'id': 'aaaaaaaa-0000-4000-8000-000000000001',
          'user_id': 'user-1',
          'title': 'Agua de jamaica',
          'category': 'Bebida',
          'prep_time': '10 min',
          'ingredients': 'Jamaica\nAzúcar',
          'instructions': 'Hervir',
          'image_url': 'https://example.com/jamaica.jpg',
          'is_favorite': 1,
          'created_at': '2026-11-20T10:00:00.000Z',
          'updated_at': '2026-11-21T10:00:00.000Z',
          'sync_status': 'synced',
        });
        await db.insert('sync_metadata', {
          'user_id': 'user-1',
          'last_synced_at': '2026-11-21T10:00:01.000Z',
        });
      },
    ),
  );
  await db.close();
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final helper = DatabaseHelper.instance;
  late String path;

  setUp(() async {
    await helper.close();
    path = p.join(await getDatabasesPath(), 'cookbook.db');
    await databaseFactory.deleteDatabase(path);
  });

  tearDown(() => helper.close());

  test(
    'v2 → v4 conserva las recetas, normaliza categoría e ingredientes',
    () async {
      await _createV2Database(path);

      // Las recetas heredadas no son visibles para ningún usuario…
      expect(await helper.getRecipesByUser('user-1'), isEmpty);
      expect(await helper.getCategories(), kDefaultCategories);

      // …hasta que el primer usuario que inicia sesión las reclama.
      expect(await helper.claimAnonymousRecipes('user-1'), 2);
      final recipes = await helper.getRecipesByUser('user-1');
      expect(recipes.map((r) => r.title), ['Flan', 'Chilaquiles']);

      final chilaquiles = recipes.last;
      expect(chilaquiles.id, hasLength(36));
      expect(chilaquiles.categoryId, categoryIdForName('Desayuno'));
      expect(chilaquiles.categoryName, 'Desayuno');
      expect(chilaquiles.ingredientList, ['Totopos', 'Salsa verde']);
      expect(chilaquiles.isFavorite, isTrue);
      expect(chilaquiles.imagePath, isNull);
      expect(chilaquiles.syncStatus, SyncStatus.pending);
      expect(recipes.first.imagePath, '/docs/flan.jpg');

      // Otro usuario no ve nada (aislamiento por user_id).
      expect(await helper.getRecipesByUser('user-2'), isEmpty);
    },
  );

  test('v3 → v4 conserva id, usuario, sync y cursor', () async {
    await _createV3Database(path);

    final recipes = await helper.getRecipesByUser('user-1');
    expect(recipes, hasLength(1));
    final jamaica = recipes.single;
    expect(jamaica.id, 'aaaaaaaa-0000-4000-8000-000000000001');
    expect(jamaica.categoryName, 'Bebida');
    expect(jamaica.ingredientList, ['Jamaica', 'Azúcar']);
    expect(jamaica.imageUrl, 'https://example.com/jamaica.jpg');
    expect(jamaica.syncStatus, SyncStatus.synced);
    expect(
      await helper.getLastSyncTime('user-1'),
      DateTime.utc(2026, 11, 21, 10, 0, 1),
    );

    // El filtro por categoría usa la clave foránea.
    final bebida = categoryIdForName('Bebida');
    expect(
      await helper.getRecipesByUser('user-1', categoryId: bebida),
      hasLength(1),
    );
    expect(
      await helper.getRecipesByUser(
        'user-1',
        categoryId: categoryIdForName('Postre'),
      ),
      isEmpty,
    );
  });

  test(
    'saveRecipe reemplaza ingredientes y respeta las claves foráneas',
    () async {
      final now = DateTime.utc(2026, 11, 25);
      const id = 'bbbbbbbb-0000-4000-8000-000000000001';
      final recipe = RecipeEntry(
        id: id,
        userId: 'user-1',
        title: 'Hot cakes',
        categoryId: categoryIdForName('Desayuno'),
        prepTime: '15 min',
        ingredients: Ingredient.fromLines(id, 'Harina\nLeche\nHuevo'),
        instructions: 'Mezclar\nCocinar',
        createdAt: now,
        updatedAt: now,
      );
      await helper.saveRecipe(recipe);
      expect((await helper.getRecipeById(id))!.ingredientList, [
        'Harina',
        'Leche',
        'Huevo',
      ]);

      // Editar reemplaza la lista completa (no duplica filas).
      await helper.saveRecipe(
        recipe.copyWith(ingredients: Ingredient.fromLines(id, 'Harina\nAgua')),
      );
      final db = await helper.database;
      final rows = await db.query(
        'ingredients',
        where: 'recipe_id = ?',
        whereArgs: [id],
      );
      expect(rows, hasLength(2));
      expect((await helper.getRecipeById(id))!.ingredientList, [
        'Harina',
        'Agua',
      ]);

      // Una categoría inexistente viola la clave foránea.
      await expectLater(
        helper.saveRecipe(
          recipe.copyWith(
            id: 'cccccccc-0000-4000-8000-000000000001',
            categoryId: 'no-existe',
            ingredients: const [],
          ),
        ),
        throwsException,
      );

      // Borrado lógico: desaparece de la lista pero queda pendiente de subir.
      await helper.softDeleteRecipe(id);
      expect(await helper.getRecipesByUser('user-1'), isEmpty);
      expect((await helper.getRecipeById(id))!.isDeleted, isTrue);
      expect(await helper.countPending('user-1'), 1);

      // markAsSynced no marca una versión que cambió después del push.
      final current = (await helper.getRecipeById(id))!;
      expect(
        await helper.markAsSynced(id, pushedUpdatedAt: DateTime.utc(2000)),
        isFalse,
      );
      expect(
        await helper.markAsSynced(id, pushedUpdatedAt: current.updatedAt),
        isTrue,
      );
      expect(await helper.countPending('user-1'), 0);
    },
  );
}
