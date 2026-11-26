import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m02_proyecto1/database/recipe_repository.dart';
import 'package:m02_proyecto1/models/ingredient.dart';
import 'package:m02_proyecto1/models/recipe_category.dart';
import 'package:m02_proyecto1/models/recipe_entry.dart';
import 'package:m02_proyecto1/models/sync_state.dart';
import 'package:m02_proyecto1/screens/home_screen.dart';
import 'package:m02_proyecto1/services/recipe_narrator.dart';
import 'package:m02_proyecto1/services/voice_service.dart';
import 'package:m02_proyecto1/widgets/recipe_card.dart';

final _created = DateTime.utc(2026, 11, 12, 10);

final _desayuno = kDefaultCategories[0];
final _bebida = kDefaultCategories[3];

final _recipe = RecipeEntry(
  id: '7',
  userId: 'user-1',
  title: 'Chilaquiles',
  categoryId: _desayuno.id,
  categoryName: _desayuno.name,
  prepTime: '20 min',
  ingredients: Ingredient.fromLines('7', 'Totopos\n\nSalsa verde'),
  instructions: 'Calentar la salsa\nAgregar totopos',
  isFavorite: true,
  createdAt: _created,
  updatedAt: _created,
  syncStatus: SyncStatus.synced,
);

/// Repositorio en memoria: demuestra que la UI no depende de SQLite (DIP).
class _FakeRepository implements RecipeRepository {
  _FakeRepository(this.recipes, {this.failuresLeft = 0});

  final List<RecipeEntry> recipes;
  int failuresLeft;

  Future<List<RecipeEntry>> _result(List<RecipeEntry> data) async {
    if (failuresLeft > 0) {
      failuresLeft--;
      throw Exception('Error al acceder a la base de datos: disco lleno');
    }
    return data;
  }

  @override
  Future<List<RecipeEntry>> getAllRecipes() => _result(recipes);

  @override
  Future<List<RecipeEntry>> getFavoriteRecipes() =>
      _result(recipes.where((r) => r.favorite).toList());

  @override
  Future<List<RecipeCategory>> getCategories() async => kDefaultCategories;

  @override
  Future<List<RecipeEntry>> getRecipesByCategory(String categoryId) =>
      _result(recipes.where((r) => r.categoryId == categoryId).toList());

  @override
  String? get currentUserId => 'user-1';

  @override
  Future<RecipeEntry> saveRecipe(RecipeEntry recipe) async => recipe;

  @override
  Future<RecipeEntry> toggleFavorite(RecipeEntry recipe) async =>
      recipe.copyWith(isFavorite: !recipe.isFavorite);

  @override
  Future<void> deleteRecipe(String id) async {}

  @override
  Future<void> syncAll() async {}

  @override
  final ValueListenable<SyncState> syncState = ValueNotifier(const SyncState());

  @override
  Stream<void> get remoteChanges => const Stream.empty();
}

/// Motor de voz falso que registra lo que se le pide leer.
class _FakeSpeechOutput implements SpeechOutput {
  final List<String> spoken = [];
  void Function()? onSpeak;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    onSpeak?.call();
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  group('RecipeEntry', () {
    test('toMap/fromMap conserva todos los campos', () {
      final copy = RecipeEntry.fromMap(
        _recipe.toMap(),
        ingredients: _recipe.ingredients,
      );
      expect(copy.toMap(), _recipe.toMap());
      expect(copy.ingredientList, ['Totopos', 'Salsa verde']);
      expect(copy.heroTag, 'recipe-hero-7');
      // Los ingredientes viven en su propia tabla, no en la fila de recipes.
      expect(_recipe.toMap().containsKey('ingredients'), isFalse);
      expect(_recipe.toMap()['category_id'], _desayuno.id);
    });

    test('Ingredient.fromLines ignora líneas vacías y numera posiciones', () {
      final list = Ingredient.fromLines('r1', ' Harina \n\nAzúcar\r\nHuevo');
      expect(list.map((i) => i.name), ['Harina', 'Azúcar', 'Huevo']);
      expect(list.map((i) => i.position), [0, 1, 2]);
      expect(list.every((i) => i.recipeId == 'r1'), isTrue);
    });

    test('fromSupabaseMap lee los ingredientes embebidos', () {
      final remote = RecipeEntry.fromSupabaseMap({
        ..._recipe.toSupabaseMap(),
        'ingredients': [
          {'id': 'b', 'recipe_id': '7', 'position': 1, 'name': 'Salsa'},
          {'id': 'a', 'recipe_id': '7', 'position': 0, 'name': 'Totopos'},
        ],
      });
      expect(remote.ingredientList, ['Totopos', 'Salsa']);
      expect(remote.categoryId, _desayuno.id);
    });

    test('toSupabaseMap excluye campos locales y fromSupabaseMap marca '
        'synced', () {
      final withImage = _recipe.copyWith(
        imagePath: '/local/foto.jpg',
        imageUrl: 'https://example.com/foto.jpg',
        syncStatus: SyncStatus.pending,
      );
      final remote = withImage.toSupabaseMap();
      expect(remote.containsKey('image_path'), isFalse);
      expect(remote.containsKey('sync_status'), isFalse);
      expect(remote['is_favorite'], isTrue);

      final back = RecipeEntry.fromSupabaseMap(remote);
      expect(back.imagePath, isNull);
      expect(back.imageUrl, 'https://example.com/foto.jpg');
      expect(back.syncStatus, SyncStatus.synced);
      expect(back.updatedAt, withImage.updatedAt);
    });

    test('newId genera UUID v4 únicos', () {
      final a = RecipeEntry.newId();
      final b = RecipeEntry.newId();
      expect(a, isNot(b));
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
          r'[0-9a-f]{12}$',
        ).hasMatch(a),
        isTrue,
      );
    });

    test('separa ingredientes y pasos ignorando líneas vacías', () {
      expect(_recipe.ingredientList, ['Totopos', 'Salsa verde']);
      expect(_recipe.instructionSteps, [
        'Calentar la salsa',
        'Agregar totopos',
      ]);
    });
  });

  group('RecipeNarrator', () {
    test('lee título, ingredientes y pasos numerados en orden', () async {
      final output = _FakeSpeechOutput();
      await RecipeNarrator(output).narrate(_recipe);
      expect(output.spoken, [
        'Chilaquiles',
        'Ingredientes: Totopos, Salsa verde.',
        'Instrucciones.',
        'Paso 1. Calentar la salsa',
        'Paso 2. Agregar totopos',
        '¡Buen provecho!',
      ]);
    });

    test('stop() evita que se lean las frases siguientes', () async {
      final output = _FakeSpeechOutput();
      final narrator = RecipeNarrator(output);
      output.onSpeak = () => narrator.stop();
      await narrator.narrate(_recipe);
      expect(output.spoken, ['Chilaquiles']);
    });
  });

  testWidgets('RecipeCard usa el Hero tag compartido por id', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecipeCard(recipe: _recipe, onTap: () {}),
        ),
      ),
    );
    expect(find.text('Chilaquiles'), findsOneWidget);
    expect(tester.widget<Hero>(find.byType(Hero)).tag, 'recipe-hero-7');
  });

  testWidgets('HomeScreen muestra el error y se recupera con Reintentar', (
    tester,
  ) async {
    final repo = _FakeRepository([_recipe], failuresLeft: 1);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(repository: repo)));
    await tester.pumpAndSettle();

    expect(find.text('Algo salió mal'), findsOneWidget);
    expect(find.textContaining('disco lleno'), findsOneWidget);

    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(find.text('Chilaquiles'), findsOneWidget);
  });

  testWidgets('Los filtros del Drawer consultan y muestran su estado vacío', (
    tester,
  ) async {
    final notFavorite = RecipeEntry(
      id: '8',
      userId: 'user-1',
      title: 'Agua de jamaica',
      categoryId: _bebida.id,
      categoryName: _bebida.name,
      prepTime: '10 min',
      ingredients: Ingredient.fromLines('8', 'Jamaica'),
      instructions: 'Hervir',
      createdAt: _created,
      updatedAt: _created,
    );
    final repo = _FakeRepository([_recipe, notFavorite]);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(repository: repo)));
    await tester.pumpAndSettle();

    Future<void> pick(String filter) async {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, filter));
      await tester.pumpAndSettle();
    }

    await pick('Mis Favoritas');
    expect(find.text('Chilaquiles'), findsOneWidget);
    expect(find.text('Agua de jamaica'), findsNothing);

    await pick('Bebida');
    expect(find.text('Agua de jamaica'), findsOneWidget);
    expect(find.text('Chilaquiles'), findsNothing);

    await pick('Postre');
    expect(find.text('No hay recetas en "Postre"'), findsOneWidget);
    expect(find.text('Crear receta'), findsOneWidget);
  });

  testWidgets('HomeScreen muestra el estado vacío', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(repository: _FakeRepository([]))),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tu recetario está vacío'), findsOneWidget);
  });
}
