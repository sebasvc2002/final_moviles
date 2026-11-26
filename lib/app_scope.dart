/// Inyección de dependencias por el árbol de widgets.
///
/// **DIP:** `main.dart` construye las implementaciones reales y las publica
/// aquí; las pantallas solo ven las abstracciones [RecipeRepository] y
/// [AuthRepository].
library;

import 'package:flutter/widgets.dart';

import 'database/recipe_repository.dart';
import 'services/auth_repository.dart';

/// Publica los repositorios de la app para todo el subárbol.
class AppScope extends InheritedWidget {
  /// Crea el scope.
  const AppScope({
    super.key,
    required this.recipes,
    required this.auth,
    required super.child,
  });

  /// Repositorio de recetas (SQLite + sync).
  final RecipeRepository recipes;

  /// Repositorio de autenticación.
  final AuthRepository auth;

  /// Scope más cercano, o `null` si no hay (por ejemplo, en pruebas).
  ///
  /// No registra dependencia (las instancias no cambian), así que se puede
  /// llamar desde `initState`.
  static AppScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>();

  /// Scope más cercano; falla si no existe.
  static AppScope of(BuildContext context) {
    final scope = maybeOf(context);
    assert(scope != null, 'No se encontró AppScope en el árbol de widgets.');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      recipes != oldWidget.recipes || auth != oldWidget.auth;
}
