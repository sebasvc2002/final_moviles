/// Formulario de creación y edición de recetas (ruta `/create`).
///
/// Si la ruta recibe una [RecipeEntry] como argumento, se edita esa receta.
///
/// **SRP:** coordina la entrada del usuario; cada tarea técnica (fotos,
/// dictado, persistencia) la resuelve un colaborador inyectado.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_scope.dart';
import '../database/recipe_repository.dart';
import '../models/ingredient.dart';
import '../models/recipe_category.dart';
import '../models/recipe_entry.dart';
import '../models/sync_state.dart';
import '../services/media_service.dart';
import '../services/voice_service.dart';
import '../widgets/sync_status_indicator.dart';
import '../widgets/voice_dictation_btn.dart';

/// Campo que está recibiendo dictado en este momento.
enum _DictationTarget { ingredients, instructions }

/// Formulario validado con foto (cámara/galería) y dictado por voz para
/// ingredientes e instrucciones. Al guardar devuelve la [RecipeEntry]
/// guardada con `Navigator.pop` para que la lista se recargue. Se guarda en
/// el dispositivo al instante y se sincroniza en segundo plano.
///
/// **DIP:** depende de abstracciones ([RecipeRepository], [ImageStorage],
/// [SpeechInput]); si no se inyectan se usan las implementaciones de
/// producción.
class FormScreen extends StatefulWidget {
  /// Crea la pantalla. Los parámetros opcionales permiten sustituir las
  /// implementaciones reales (por ejemplo, en pruebas).
  const FormScreen({
    super.key,
    this.repository,
    this.imageStorage,
    this.speechInput,
  });

  /// Repositorio de recetas; por defecto el de [AppScope].
  final RecipeRepository? repository;

  /// Almacén de imágenes; por defecto [MediaService].
  final ImageStorage? imageStorage;

  /// Motor de dictado; por defecto [VoiceService].
  final SpeechInput? speechInput;

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _prepTimeCtrl = TextEditingController();
  final _ingredientsCtrl = TextEditingController();
  final _instructionsCtrl = TextEditingController();

  late final RecipeRepository _repository =
      widget.repository ?? AppScope.of(context).recipes;
  late final ImageStorage _media = widget.imageStorage ?? MediaService();
  late final SpeechInput _voice = widget.speechInput ?? VoiceService();

  /// Receta en edición (argumento de la ruta) o `null` al crear.
  RecipeEntry? _editing;
  bool _initialized = false;

  /// Filas de la tabla `categories` para el selector.
  List<RecipeCategory> _categories = const [];
  String? _categoryId;
  String? _imagePath;

  /// Foto que ya tenía la receta en edición; no se borra si se cancela.
  String? _originalImagePath;
  bool _pickingImage = false;
  bool _saving = false;
  bool _saved = false;

  _DictationTarget? _listeningTarget;

  /// Texto que tenía el campo antes de empezar a dictar; el dictado se añade
  /// al final como una línea nueva.
  String _textBeforeDictation = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final arg = ModalRoute.of(context)?.settings.arguments;
    if (arg is RecipeEntry) {
      _editing = arg;
      _titleCtrl.text = arg.title;
      _prepTimeCtrl.text = arg.prepTime;
      _ingredientsCtrl.text = arg.ingredientsText;
      _instructionsCtrl.text = arg.instructions;
      _categoryId = arg.categoryId;
      _imagePath = arg.imagePath;
      _originalImagePath = arg.imagePath;
    }
    _loadCategories();
  }

  /// Carga las categorías de SQLite y selecciona la primera si hace falta.
  Future<void> _loadCategories() async {
    try {
      final categories = await _repository.getCategories();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        if (!categories.any((c) => c.id == _categoryId)) {
          _categoryId = categories.isEmpty ? null : categories.first.id;
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  void dispose() {
    _voice.dispose();
    _titleCtrl.dispose();
    _prepTimeCtrl.dispose();
    _ingredientsCtrl.dispose();
    _instructionsCtrl.dispose();
    // Si la receta no se guardó, no dejamos la foto huérfana en disco.
    final path = _imagePath;
    if (!_saved && path != null && path != _originalImagePath) {
      _media.deleteImage(path);
    }
    super.dispose();
  }

  TextEditingController _controllerFor(_DictationTarget target) =>
      target == _DictationTarget.ingredients
      ? _ingredientsCtrl
      : _instructionsCtrl;

  // ---------------------------------------------------------------------------
  // Multimedia
  // ---------------------------------------------------------------------------

  /// Obtiene una foto de [source] y reemplaza la anterior (que se borra).
  Future<void> _pickImage(ImageSource source) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _pickingImage = true);
    try {
      final path = await _media.pickAndSaveImage(source);
      if (!mounted || path == null) return;
      final previous = _imagePath;
      setState(() => _imagePath = path);
      if (previous != null && previous != _originalImagePath) {
        await _media.deleteImage(previous);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Dictado por voz
  // ---------------------------------------------------------------------------

  /// Inicia o detiene el dictado en [target]. El texto reconocido se añade
  /// como línea nueva al final de lo que ya tenía el campo.
  Future<void> _toggleDictation(_DictationTarget target) async {
    final messenger = ScaffoldMessenger.of(context);
    // Pulsar el botón activo detiene el dictado.
    if (_listeningTarget == target) {
      await _voice.stopListening();
      return;
    }
    // Si se estaba dictando en otro campo, se detiene primero.
    if (_listeningTarget != null) {
      await _voice.stopListening();
    }

    final ready = await _voice.initSpeech();
    if (!mounted) return;
    if (!ready) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'El dictado no está disponible. Revisa el permiso de micrófono.',
          ),
        ),
      );
      return;
    }

    final controller = _controllerFor(target);
    _textBeforeDictation = controller.text.trimRight();
    setState(() => _listeningTarget = target);

    _voice.startListening(
      onResult: (words) {
        if (!mounted || words.isEmpty) return;
        final prefix = _textBeforeDictation.isEmpty
            ? ''
            : '$_textBeforeDictation\n';
        final text = '$prefix$words';
        controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _listeningTarget = null);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Guardado
  // ---------------------------------------------------------------------------

  /// Valida el formulario y guarda la receta.
  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_listeningTarget != null) await _voice.stopListening();
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);

    try {
      final now = DateTime.now().toUtc();
      final editing = _editing;
      // UUID v4 generado en el cliente: válido aun sin conexión.
      final id = editing?.id ?? RecipeEntry.newId();
      // Cada línea del campo se guarda como una fila de `ingredients`.
      final ingredients = Ingredient.fromLines(id, _ingredientsCtrl.text);
      final recipe = editing != null
          ? editing.copyWith(
              title: _titleCtrl.text.trim(),
              categoryId: _categoryId,
              prepTime: _prepTimeCtrl.text.trim(),
              ingredients: ingredients,
              instructions: _instructionsCtrl.text.trim(),
              imagePath: _imagePath,
            )
          : RecipeEntry(
              id: id,
              userId: _repository.currentUserId ?? '',
              title: _titleCtrl.text.trim(),
              categoryId: _categoryId!,
              prepTime: _prepTimeCtrl.text.trim(),
              ingredients: ingredients,
              instructions: _instructionsCtrl.text.trim(),
              imagePath: _imagePath,
              createdAt: now,
              updatedAt: now,
            );

      final saved = await _repository.saveRecipe(recipe);
      _saved = true;
      // Si se reemplazó la foto, la anterior ya no se usa.
      final original = _originalImagePath;
      if (original != null && original != saved.imagePath) {
        await _media.deleteImage(original);
      }
      final offline = _repository.syncState.value.phase == SyncPhase.offline;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            offline
                ? 'Receta guardada en el dispositivo. Se sincronizará al '
                      'recuperar la conexión.'
                : '¡Receta guardada con éxito!',
          ),
        ),
      );
      navigator.pop(saved);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('No se pudo guardar la receta: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Devuelve [message] si el campo está vacío.
  static FormFieldValidator<String> _required(String message) {
    return (value) => (value == null || value.trim().isEmpty) ? message : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing == null ? 'Nueva receta' : 'Editar receta'),
        actions: [
          SyncStatusIndicator(
            state: _repository.syncState,
            onSync: _repository.syncAll,
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildMediaSection(context),
              const SizedBox(height: 24),
              TextFormField(
                controller: _titleCtrl,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Título',
                  prefixIcon: Icon(Icons.restaurant_menu),
                ),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: _required('El título es obligatorio'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                // Se recrea cuando llegan las categorías para tomar el valor.
                key: ValueKey(_categories.length),
                initialValue: _categoryId,
                decoration: const InputDecoration(
                  labelText: 'Categoría',
                  prefixIcon: Icon(Icons.category_outlined),
                ),
                items: [
                  for (final c in _categories)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                validator: (v) => v == null ? 'Elige una categoría' : null,
                onChanged: (v) {
                  if (v != null) setState(() => _categoryId = v);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _prepTimeCtrl,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Tiempo de preparación',
                  hintText: 'Ej. 30 min',
                  prefixIcon: Icon(Icons.timer_outlined),
                ),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: _required('El tiempo de preparación es obligatorio'),
              ),
              const SizedBox(height: 16),
              _DictationField(
                controller: _ingredientsCtrl,
                label: 'Ingredientes',
                hint: 'Uno por línea, o dicta con el micrófono',
                icon: Icons.shopping_basket_outlined,
                isListening: _listeningTarget == _DictationTarget.ingredients,
                onMicPressed: () =>
                    _toggleDictation(_DictationTarget.ingredients),
                validator: _required('Los ingredientes son obligatorios'),
              ),
              const SizedBox(height: 16),
              _DictationField(
                controller: _instructionsCtrl,
                label: 'Instrucciones',
                hint: 'Un paso por línea, o dicta con el micrófono',
                icon: Icons.format_list_numbered,
                isListening: _listeningTarget == _DictationTarget.instructions,
                onMicPressed: () =>
                    _toggleDictation(_DictationTarget.instructions),
                validator: _required('Las instrucciones son obligatorias'),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                icon: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? 'Guardando…' : 'Guardar Receta'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Vista previa de la foto y botones "Tomar Foto" / "Galería".
  Widget _buildMediaSection(BuildContext context) {
    final theme = Theme.of(context);
    final path = _imagePath;
    final remoteUrl = path == null ? _editing?.imageUrl : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              color: const Color(0xFF1E1E1E),
              child: _pickingImage
                  ? const Center(child: CircularProgressIndicator())
                  : remoteUrl != null
                  ? Image.network(
                      remoteUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined),
                      ),
                    )
                  : path == null
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_a_photo_outlined,
                          size: 48,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 8),
                        const Text('Agrega una foto de tu platillo'),
                      ],
                    )
                  : Image.file(File(path), fit: BoxFit.cover),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickingImage
                    ? null
                    : () => _pickImage(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Tomar Foto'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickingImage
                    ? null
                    : () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Galería'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Campo multilínea con el botón de dictado a la derecha.
class _DictationField extends StatelessWidget {
  const _DictationField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    required this.isListening,
    required this.onMicPressed,
    required this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool isListening;
  final VoidCallback onMicPressed;
  final FormFieldValidator<String> validator;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            controller: controller,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: label,
              hintText: isListening ? 'Escuchando…' : hint,
              prefixIcon: Icon(icon),
              alignLabelWithHint: true,
            ),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: validator,
          ),
        ),
        const SizedBox(width: 12),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: VoiceDictationBtn(
            isListening: isListening,
            onPressed: onMicPressed,
          ),
        ),
      ],
    );
  }
}
