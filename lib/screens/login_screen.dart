/// Pantalla de inicio de sesión (raíz cuando no hay sesión).
///
/// **SRP / DIP:** solo valida el formulario y delega en [AuthRepository];
/// no conoce Supabase. El cambio a la lista lo hace `AuthGate` al detectar
/// la nueva sesión.
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/auth_repository.dart';
import 'auth_form.dart';

/// Formulario de correo y contraseña con enlace a registro.
class LoginScreen extends StatefulWidget {
  /// Crea la pantalla. [auth] permite inyectar otra implementación.
  const LoginScreen({super.key, this.auth});

  /// Repositorio de autenticación; por defecto el de [AppScope].
  final AuthRepository? auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final AuthRepository _auth = widget.auth ?? AppScope.of(context).auth;
  bool _loading = false;

  Future<void> _submit(String email, String password) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _loading = true);
    try {
      await _auth.signIn(email, password);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthFormScaffold(
      title: 'Bienvenido a CookBook',
      subtitle: 'Inicia sesión para sincronizar tus recetas',
      submitLabel: 'Iniciar sesión',
      loading: _loading,
      onSubmit: _submit,
      footer: TextButton(
        onPressed: _loading
            ? null
            : () => Navigator.pushNamed(context, '/register'),
        child: const Text('¿No tienes cuenta? Regístrate'),
      ),
    );
  }
}
