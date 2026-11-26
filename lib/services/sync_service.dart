/// Motor de sincronización bidireccional SQLite ⇄ Supabase.
///
/// **SRP:** decide *qué* subir y bajar y cómo resolver conflictos
/// (Last-Write-Wins por `updated_at`). No conoce la UI; publica su estado en
/// [SyncService.state] y avisa de cambios remotos en [SyncService.changes].
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../database/database_helper.dart';
import '../models/recipe_entry.dart';
import '../models/sync_state.dart';
import 'supabase_service.dart';

/// Coordina push/pull, conectividad y el estado observable de la sync.
class SyncService {
  /// Crea el servicio. [connectivity] permite inyectar un doble de prueba.
  SyncService({
    required this._local,
    required this._remote,
    Connectivity? connectivity,
  }) : _connectivity = connectivity ?? Connectivity();

  final DatabaseHelper _local;
  final RemoteRecipeStore _remote;
  final Connectivity _connectivity;

  final ValueNotifier<SyncState> _state = ValueNotifier(const SyncState());
  final StreamController<void> _changes = StreamController<void>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  String? Function()? _currentUserId;
  bool _wasOffline = false;

  /// Sincronización en curso (actúa como mutex) y bandera para repetirla si
  /// llegan cambios mientras corre.
  Future<void>? _running;
  bool _rerunRequested = false;

  /// Estado actual para la UI.
  ValueListenable<SyncState> get state => _state;

  /// Emite cada vez que un pull modificó recetas locales.
  Stream<void> get changes => _changes.stream;

  /// Empieza a escuchar la conectividad: al volver la red se sincroniza el
  /// usuario que devuelva [currentUserId]. Llamarlo de nuevo solo actualiza
  /// el proveedor del usuario.
  void start(String? Function() currentUserId) {
    _currentUserId = currentUserId;
    _connectivitySub ??= _connectivity.onConnectivityChanged.listen((results) {
      final online = _isOnline(results);
      if (online && _wasOffline) {
        final userId = _currentUserId?.call();
        if (userId != null) unawaited(syncAll(userId));
      }
      _wasOffline = !online;
      if (!online) _setPhase(SyncPhase.offline);
    });
  }

  /// Deja de escuchar la conectividad y libera recursos.
  Future<void> dispose() async {
    await _connectivitySub?.cancel();
    await _changes.close();
    _state.dispose();
  }

  static bool _isOnline(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  void _setPhase(SyncPhase phase, {String? message}) {
    _state.value = _state.value.copyWith(
      phase: phase,
      message: message,
      clearMessage: message == null,
    );
  }

  /// Recalcula cuántas recetas de [userId] faltan por subir.
  Future<void> refreshPendingCount(String userId) async {
    try {
      final pending = await _local.countPending(userId);
      _state.value = _state.value.copyWith(pendingCount: pending);
    } catch (e) {
      debugPrint('[SyncService] refreshPendingCount: $e');
    }
  }

  /// Reinicia el estado (por ejemplo, al cerrar sesión).
  void reset() => _state.value = const SyncState();

  /// Sincroniza a [userId]. Si ya hay una sincronización en curso no se
  /// lanza otra en paralelo: se marca para repetirse al terminar y se
  /// devuelve el mismo `Future`. Nunca lanza; los errores van a [state].
  Future<void> syncAll(String userId) {
    final running = _running;
    if (running != null) {
      _rerunRequested = true;
      return running;
    }
    final future = _loop(userId).whenComplete(() => _running = null);
    _running = future;
    return future;
  }

  Future<void> _loop(String userId) async {
    do {
      _rerunRequested = false;
      await _syncOnce(userId);
    } while (_rerunRequested);
  }

  Future<void> _syncOnce(String userId) async {
    try {
      final online = _isOnline(await _connectivity.checkConnectivity());
      _wasOffline = !online;
      if (!online) {
        await refreshPendingCount(userId);
        _setPhase(SyncPhase.offline);
        return;
      }

      _setPhase(SyncPhase.syncing);
      // Primero PULL: así un cambio remoto más nuevo gana (LWW) antes de que
      // el PUSH pueda sobrescribirlo con una versión local más vieja.
      final pulled = await _pull(userId);
      final pushErrors = await _push(userId);

      await refreshPendingCount(userId);
      if (pulled) _changes.add(null);

      if (pushErrors.isEmpty) {
        _state.value = _state.value.copyWith(
          phase: SyncPhase.synced,
          lastSyncedAt: DateTime.now().toUtc(),
          clearMessage: true,
        );
      } else {
        _setPhase(SyncPhase.error, message: pushErrors.first);
      }
    } catch (e) {
      debugPrint('[SyncService] Sincronización fallida: $e');
      await refreshPendingCount(userId);
      _setPhase(SyncPhase.error, message: 'No se pudo sincronizar: $e');
    }
  }

  /// Baja los cambios remotos y los aplica con Last-Write-Wins. Devuelve
  /// `true` si alguna receta local cambió.
  Future<bool> _pull(String userId) async {
    // Las categorías van primero: las recetas las referencian por FK.
    final categories = await _remote.fetchCategories();
    if (categories.isNotEmpty) await _local.upsertCategories(categories);

    final lastSync = await _local.getLastSyncTime(userId);
    final delta = await _remote.fetchUpdatedRecipes(userId, lastSync);
    var changed = false;

    for (final remote in delta.recipes) {
      final local = await _local.getRecipeById(remote.id);
      if (local != null && !remote.updatedAt.isAfter(local.updatedAt)) {
        // La copia local es igual o más nueva: se conserva (y si está
        // pendiente, el push la subirá).
        continue;
      }
      // La foto local sigue siendo válida solo si la remota es la misma.
      final keepLocalImage =
          local?.imagePath != null && local?.imageUrl == remote.imageUrl;
      // Guarda la receta y reemplaza sus ingredientes en una transacción.
      await _local.saveRecipe(
        remote.copyWith(
          imagePath: keepLocalImage ? local!.imagePath : null,
          syncStatus: SyncStatus.synced,
        ),
      );
      changed = true;
    }

    final cursor = delta.cursor;
    if (cursor != null) await _local.setLastSyncTime(userId, cursor);
    return changed;
  }

  /// Sube las recetas pendientes (fotos incluidas). Cada receta se procesa
  /// por separado para que un fallo no bloquee a las demás. Devuelve los
  /// mensajes de error.
  Future<List<String>> _push(String userId) async {
    final errors = <String>[];
    final pending = await _local.getPendingRecipes(userId);

    for (final item in pending) {
      try {
        var imageUrl = item.imageUrl;
        if (!item.isDeleted && item.imagePath != null && imageUrl == null) {
          imageUrl = await _remote.uploadRecipeImage(item);
        }
        final applied = await _remote.upsertRecipe(
          item.copyWith(imageUrl: imageUrl),
        );
        if (!applied) {
          // El servidor tiene una versión más nueva (LWW): la local pierde y
          // se reemplazará en el próximo pull.
          debugPrint('[SyncService] ${item.id}: gana la versión remota.');
        }
        await _local.markAsSynced(
          item.id,
          pushedUpdatedAt: item.updatedAt,
          imageUrl: imageUrl,
        );
      } catch (e) {
        debugPrint('[SyncService] No se pudo subir ${item.id}: $e');
        errors.add('No se pudo subir "${item.title}": $e');
      }
    }
    return errors;
  }
}
