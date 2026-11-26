/// Pantalla de detalle de una receta (ruta `/detail`).
///
/// **SRP:** solo presenta la receta y traduce los toques del usuario a
/// llamadas a sus colaboradores. La lógica de narración vive en
/// [RecipeNarrator] y la persistencia en [RecipeRepository].
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../database/recipe_repository.dart';
import '../models/recipe_entry.dart';
import '../services/media_service.dart';
import '../services/recipe_narrator.dart';
import '../services/voice_service.dart';
import '../widgets/recipe_card.dart';

/// Muestra la receta recibida como argumento de la ruta nombrada, con
/// cabecera Hero, botón de favorito, borrado y lectura en voz alta.
///
/// **DIP:** las dependencias se pueden inyectar; si se omiten se usan las
/// implementaciones de producción.
class DetailScreen extends StatefulWidget {
  /// Crea la pantalla. Los parámetros opcionales permiten sustituir las
  /// implementaciones reales (por ejemplo, en pruebas).
  const DetailScreen({
    super.key,
    this.repository,
    this.imageStorage,
    this.speechOutput,
  });

  /// Repositorio de recetas; por defecto el de [AppScope].
  final RecipeRepository? repository;

  /// Almacén de imágenes; por defecto [MediaService].
  final ImageStorage? imageStorage;

  /// Motor de lectura en voz alta; por defecto [VoiceService].
  final SpeechOutput? speechOutput;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late final RecipeRepository _repository =
      widget.repository ?? AppScope.of(context).recipes;
  late final ImageStorage _images = widget.imageStorage ?? MediaService();
  late final RecipeNarrator _narrator = RecipeNarrator(
    widget.speechOutput ?? VoiceService(),
  );

  RecipeEntry? _recipe;
  bool _isSpeaking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // La receta llega por la ruta nombrada '/detail'.
    _recipe ??= ModalRoute.of(context)!.settings.arguments as RecipeEntry;
  }

  @override
  void dispose() {
    _narrator.dispose();
    super.dispose();
  }

  /// Marca o desmarca la receta como favorita y actualiza la vista.
  Future<void> _toggleFavorite() async {
    final recipe = _recipe!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated = await _repository.toggleFavorite(recipe);
      if (!mounted) return;
      setState(() => _recipe = updated);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            updated.isFavorite
                ? 'Agregada a favoritas'
                : 'Quitada de favoritas',
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  /// Inicia la lectura de la receta o, si ya está sonando, la detiene.
  Future<void> _toggleSpeech() async {
    if (_isSpeaking) {
      await _narrator.stop();
      if (mounted) setState(() => _isSpeaking = false);
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isSpeaking = true);
    try {
      await _narrator.narrate(_recipe!);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _isSpeaking = false);
    }
  }

  /// Abre el formulario en modo edición y refresca la vista al volver.
  Future<void> _edit() async {
    await _narrator.stop();
    if (!mounted) return;
    final updated = await Navigator.pushNamed<Object?>(
      context,
      '/create',
      arguments: _recipe,
    );
    if (!mounted || updated is! RecipeEntry) return;
    setState(() => _recipe = updated);
  }

  /// Pide confirmación, borra la receta y su foto, y vuelve a la lista.
  Future<void> _delete() async {
    final recipe = _recipe!;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar receta'),
        content: Text('¿Seguro que deseas eliminar "${recipe.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await _narrator.stop();
      // Borrado lógico: se propaga a otros dispositivos en la próxima sync.
      await _repository.deleteRecipe(recipe.id);
      final path = recipe.imagePath;
      if (path != null) await _images.deleteImage(path);
      messenger.showSnackBar(const SnackBar(content: Text('Receta eliminada')));
      navigator.pop(true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final recipe = _recipe!;
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 300,
            actions: [
              IconButton(
                tooltip: recipe.favorite
                    ? 'Quitar de favoritas'
                    : 'Marcar como favorita',
                icon: Icon(
                  recipe.favorite ? Icons.favorite : Icons.favorite_border,
                  color: accent,
                ),
                onPressed: _toggleFavorite,
              ),
              IconButton(
                tooltip: 'Editar',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _edit,
              ),
              IconButton(
                tooltip: 'Eliminar',
                icon: const Icon(Icons.delete_outline),
                onPressed: _delete,
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Hero(
                tag: recipe.heroTag,
                child: RecipeImage(recipe: recipe, iconSize: 96),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
            sliver: SliverList.list(
              children: [
                Text(
                  recipe.title,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      avatar: Icon(Icons.category_outlined, color: accent),
                      label: Text(recipe.categoryName),
                    ),
                    Chip(
                      avatar: Icon(Icons.timer_outlined, color: accent),
                      label: Text(recipe.prepTime),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _Section(
                  icon: Icons.shopping_basket_outlined,
                  title: 'Ingredientes',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final item in recipe.ingredientList)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.circle, size: 8, color: accent),
                              const SizedBox(width: 10),
                              Expanded(child: Text(item)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _Section(
                  icon: Icons.format_list_numbered,
                  title: 'Instrucciones',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (i, step) in recipe.instructionSteps.indexed)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 12,
                                backgroundColor: accent,
                                child: Text(
                                  '${i + 1}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: Text(step)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleSpeech,
        icon: Icon(_isSpeaking ? Icons.stop_rounded : Icons.volume_up_rounded),
        label: Text(_isSpeaking ? 'Detener Audio' : 'Escuchar Receta'),
      ),
    );
  }
}

/// Tarjeta con icono, título y contenido; agrupa ingredientes o pasos.
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            child,
          ],
        ),
      ),
    );
  }
}
