/// Punto de entrada de CookBook.
///
/// **Raíz de composición (DIP):** aquí se inicializa Supabase, se construyen
/// las implementaciones reales (SQLite, Supabase, sincronización) y se
/// publican con [AppScope]. Las pantallas solo ven abstracciones.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_scope.dart';
import 'config/supabase_config.dart';
import 'database/database_helper.dart';
import 'database/local_first_recipe_repository.dart';
import 'screens/detail_screen.dart';
import 'screens/form_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'services/auth_repository.dart';
import 'services/supabase_service.dart';
import 'services/sync_service.dart';

/// Arranca la aplicación.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!SupabaseConfig.isConfigured) {
    runApp(const _MissingConfigApp());
    return;
  }

  // Restaura la sesión guardada aunque no haya red, así la app abre
  // directamente en la lista y funciona sin conexión.
  await Supabase.initialize(
    url: SupabaseConfig.url,
    // `publishableKey` acepta tanto la clave anon clásica como la nueva
    // clave publicable de Supabase.
    publishableKey: SupabaseConfig.anonKey,
  );

  final supabase = SupabaseService();
  final sync = SyncService(local: DatabaseHelper.instance, remote: supabase);
  final repository = LocalFirstRecipeRepository(
    local: DatabaseHelper.instance,
    sync: sync,
    auth: supabase,
  );

  runApp(
    AppScope(
      recipes: repository,
      auth: supabase,
      child: CookBookApp(
        onSignedIn: repository.activateSession,
        onSignedOut: repository.deactivateSession,
      ),
    ),
  );
}

/// Fondo carbón de la paleta culinaria oscura.
const Color kCharcoal = Color(0xFF121212);

/// Color de tarjetas y campos.
const Color kCardColor = Color(0xFF1E1E1E);

/// Acento naranja vibrante.
const Color kAccentOrange = Color(0xFFFF6B35);

/// Widget raíz: tema oscuro, [AuthGate] como inicio y rutas nombradas
/// (`/detail`, `/create`, `/register`).
class CookBookApp extends StatelessWidget {
  /// Crea la aplicación. Los callbacks se invocan cuando cambia la sesión.
  const CookBookApp({super.key, this.onSignedIn, this.onSignedOut});

  /// Se llama con el id del usuario al iniciar sesión.
  final Future<void> Function(String userId)? onSignedIn;

  /// Se llama al cerrar sesión.
  final VoidCallback? onSignedOut;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CookBook',
      debugShowCheckedModeBanner: false,
      theme: buildCookBookTheme(),
      home: AuthGate(onSignedIn: onSignedIn, onSignedOut: onSignedOut),
      routes: {
        '/detail': (context) => const DetailScreen(),
        '/create': (context) => const FormScreen(),
        '/register': (context) => const RegisterScreen(),
      },
    );
  }
}

/// Elige la pantalla inicial según la sesión: [LoginScreen] sin sesión y
/// [HomeScreen] con sesión. Al cambiar de usuario dispara la preparación de
/// la sesión (reclamar recetas locales + sincronización inicial).
class AuthGate extends StatefulWidget {
  /// Crea la compuerta. [auth] permite inyectar otra implementación.
  const AuthGate({super.key, this.auth, this.onSignedIn, this.onSignedOut});

  /// Repositorio de autenticación; por defecto el de [AppScope].
  final AuthRepository? auth;

  /// Ver [CookBookApp.onSignedIn].
  final Future<void> Function(String userId)? onSignedIn;

  /// Ver [CookBookApp.onSignedOut].
  final VoidCallback? onSignedOut;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final AuthRepository _auth = widget.auth ?? AppScope.of(context).auth;
  StreamSubscription<String?>? _sub;
  String? _userId;

  @override
  void initState() {
    super.initState();
    _userId = _auth.currentUserId;
    final initial = _userId;
    if (initial != null) _activate(initial);
    _sub = _auth.userIdChanges.listen(_onUserChanged);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _activate(String userId) {
    final callback = widget.onSignedIn;
    if (callback != null) unawaited(callback(userId));
  }

  void _onUserChanged(String? userId) {
    if (!mounted || userId == _userId) return;
    // Cierra pantallas apiladas (registro, detalle…) de la sesión anterior.
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => _userId = userId);
    if (userId != null) {
      _activate(userId);
    } else {
      widget.onSignedOut?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = _userId;
    if (userId == null) return const LoginScreen();
    // La clave reinicia el estado de la lista al cambiar de usuario.
    return HomeScreen(key: ValueKey(userId));
  }
}

/// Pantalla mostrada cuando se compiló sin `SUPABASE_URL`/`SUPABASE_ANON_KEY`.
class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildCookBookTheme(),
      home: const Scaffold(
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Falta la configuración de Supabase.\n\n'
                'Copia .env.example a .env, llena SUPABASE_URL y '
                'SUPABASE_ANON_KEY y ejecuta:\n\n'
                'flutter run --dart-define-from-file=.env',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Construye el tema oscuro a partir de `ThemeData.dark()`.
ThemeData buildCookBookTheme() {
  final base = ThemeData.dark();
  final scheme = base.colorScheme.copyWith(
    primary: kAccentOrange,
    onPrimary: Colors.white,
    secondary: kAccentOrange,
    onSecondary: Colors.white,
    surface: kCardColor,
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: kCharcoal,
    appBarTheme: const AppBarTheme(
      backgroundColor: kCharcoal,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: kCardColor,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: kCharcoal),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: kAccentOrange,
      foregroundColor: Colors.white,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: kCardColor,
      side: BorderSide.none,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kCardColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kAccentOrange, width: 2),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
