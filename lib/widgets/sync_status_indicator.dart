/// Ícono del AppBar que muestra el estado de sincronización.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/sync_state.dart';

/// Dibuja [state] como ícono (con insignia de pendientes) y lanza [onSync]
/// al tocarlo.
class SyncStatusIndicator extends StatelessWidget {
  /// Crea el indicador.
  const SyncStatusIndicator({super.key, required this.state, this.onSync});

  /// Estado observable de la sincronización.
  final ValueListenable<SyncState> state;

  /// Acción al tocar (normalmente sincronizar ahora).
  final VoidCallback? onSync;

  static String _tooltip(SyncState s) {
    final pending = s.pendingCount > 0
        ? ' · ${s.pendingCount} cambio(s) sin subir'
        : '';
    return switch (s.phase) {
      SyncPhase.idle => 'Sincronizar$pending',
      SyncPhase.syncing => 'Sincronizando…',
      SyncPhase.synced => 'Sincronizado$pending',
      SyncPhase.offline => 'Sin conexión: guardado en el dispositivo$pending',
      SyncPhase.error => 'Error al sincronizar$pending',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<SyncState>(
      valueListenable: state,
      builder: (context, s, _) {
        final Widget icon = switch (s.phase) {
          SyncPhase.syncing => const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SyncPhase.synced when s.pendingCount == 0 => const Icon(
            Icons.cloud_done_outlined,
          ),
          SyncPhase.offline => const Icon(Icons.cloud_off_outlined),
          SyncPhase.error => Icon(
            Icons.sync_problem,
            color: theme.colorScheme.error,
          ),
          _ => const Icon(Icons.cloud_upload_outlined),
        };
        return IconButton(
          tooltip: _tooltip(s),
          onPressed: s.phase == SyncPhase.syncing ? null : onSync,
          icon: Badge(
            isLabelVisible: s.pendingCount > 0 && s.phase != SyncPhase.syncing,
            label: Text('${s.pendingCount}'),
            child: icon,
          ),
        );
      },
    );
  }
}
