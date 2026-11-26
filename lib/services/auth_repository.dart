/// Contrato de autenticación que usa la UI.
///
/// **DIP:** las pantallas de acceso dependen de esta abstracción y no de
/// Supabase; `SupabaseService` es la implementación de producción.
library;

/// Resultado de un registro.
enum SignUpResult {
  /// La cuenta se creó y ya hay sesión iniciada.
  signedIn,

  /// La cuenta se creó pero el proyecto exige confirmar el correo.
  confirmationRequired,
}

/// Operaciones de sesión. Todas lanzan una [Exception] con un mensaje
/// legible si fallan.
abstract interface class AuthRepository {
  /// Id del usuario con sesión iniciada, o `null`.
  String? get currentUserId;

  /// Correo del usuario con sesión iniciada, o `null`.
  String? get currentUserEmail;

  /// Emite el id del usuario cada vez que cambia la sesión (`null` al salir).
  Stream<String?> get userIdChanges;

  /// Inicia sesión con correo y contraseña.
  Future<void> signIn(String email, String password);

  /// Crea una cuenta nueva.
  Future<SignUpResult> signUp(String email, String password);

  /// Cierra la sesión actual.
  Future<void> signOut();
}
