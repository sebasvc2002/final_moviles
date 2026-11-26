/// Pantalla de registro (ruta `/register`).
library;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../services/auth_repository.dart';
import 'auth_form.dart';

/// Crea una cuenta nueva. Si el proyecto exige confirmar el correo, lo
/// indica y vuelve al inicio de sesión.
class RegisterScreen extends StatefulWidget {
  /// Crea la pantalla. [auth] permite inyectar otra implementación.
  const RegisterScreen({super.key, this.auth});

  /// Repositorio de autenticación; por defecto el de [AppScope].
  final AuthRepository? auth;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  late final AuthRepository _auth = widget.auth ?? AppScope.of(context).auth;
  bool _loading = false;

  Future<void> _submit(String email, String password) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _loading = true);
    try {
      final result = await _auth.signUp(email, password);
      if (result == SignUpResult.confirmationRequired) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Cuenta creada. Revisa tu correo para confirmarla y luego '
              'inicia sesión.',
            ),
          ),
        );
        if (navigator.canPop()) navigator.pop();
      }
      // Con sesión iniciada, AuthGate cierra esta pantalla automáticamente.
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
      title: 'Crea tu cuenta',
      subtitle: 'Tus recetas se guardarán en la nube y en tu dispositivo',
      submitLabel: 'Registrarme',
      loading: _loading,
      confirmPassword: true,
      onSubmit: _submit,
      showBackButton: true,
      footer: TextButton(
        onPressed: _loading ? null : () => Navigator.pop(context),
        child: const Text('¿Ya tienes cuenta? Inicia sesión'),
      ),
    );
  }
}
