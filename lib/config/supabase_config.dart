/// Configuración de Supabase leída en tiempo de compilación.
///
/// Los valores llegan con `--dart-define-from-file=.env` (o con
/// `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...`), así
/// que ninguna clave queda escrita en el código fuente. Ver `.env.example`.
library;

/// Valores de conexión al proyecto de Supabase.
abstract final class SupabaseConfig {
  /// URL del proyecto, por ejemplo `https://xyzcompany.supabase.co`.
  static const String url = String.fromEnvironment('SUPABASE_URL');

  /// Clave pública `anon` del proyecto (segura en el cliente gracias a RLS).
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Bucket de Storage donde se guardan las fotos de las recetas.
  static const String imagesBucket = 'recipe-images';

  /// Tabla remota de recetas.
  static const String recipesTable = 'recipes';

  /// Tabla remota de categorías.
  static const String categoriesTable = 'categories';

  /// Indica si se proporcionaron ambos valores al compilar.
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;
}
