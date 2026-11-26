/// Estado observable de la sincronización, independiente de Supabase.
library;

/// Fase actual del motor de sincronización.
enum SyncPhase {
  /// Aún no se ha intentado sincronizar en esta sesión.
  idle,

  /// Hay una sincronización en curso.
  syncing,

  /// La última sincronización terminó sin errores.
  synced,

  /// No hay conexión; los cambios quedan guardados en el dispositivo.
  offline,

  /// La última sincronización falló (se reintentará).
  error,
}

/// Instantánea inmutable del estado de sincronización que la UI dibuja.
class SyncState {
  /// Crea el estado.
  const SyncState({
    this.phase = SyncPhase.idle,
    this.pendingCount = 0,
    this.lastSyncedAt,
    this.message,
  });

  /// Fase actual.
  final SyncPhase phase;

  /// Recetas con cambios locales que aún no se suben.
  final int pendingCount;

  /// Momento (UTC) de la última sincronización completa, si la hubo.
  final DateTime? lastSyncedAt;

  /// Detalle del error para mostrar al usuario, si [phase] es `error`.
  final String? message;

  /// Devuelve una copia con los campos indicados reemplazados.
  SyncState copyWith({
    SyncPhase? phase,
    int? pendingCount,
    DateTime? lastSyncedAt,
    String? message,
    bool clearMessage = false,
  }) {
    return SyncState(
      phase: phase ?? this.phase,
      pendingCount: pendingCount ?? this.pendingCount,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      message: clearMessage ? null : (message ?? this.message),
    );
  }
}
