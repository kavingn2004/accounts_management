import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_config.dart';
import '../../core/theme.dart';

/// Email + password sign in / sign up against Supabase Auth. Shown before the
/// PIN gate whenever the app is configured for cloud sync and no user is signed
/// in. On success the auth stream updates and AuthGate moves on automatically.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _isSignUp = false;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    final auth = Supabase.instance.client.auth;
    final email = _email.text.trim();
    final password = _password.text;
    try {
      if (_isSignUp) {
        final res = await auth.signUp(
          email: email,
          password: password,
          // Without this the confirmation link points at the project's Site
          // URL, which defaults to localhost — a dead link for everyone who
          // is not the developer.
          emailRedirectTo: SupabaseConfig.emailRedirectTo,
        );
        // If email confirmation is on, there's no session yet.
        if (res.session == null && mounted) {
          setState(() {
            _isSignUp = false;
            _info = 'Account created. Check your email to confirm, then sign in.';
          });
        }
      } else {
        await auth.signInWithPassword(email: email, password: password);
      }
      // On success, the session stream updates and AuthGate rebuilds.
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: context.colors.surface,
                        border: Border.all(color: context.colors.border),
                        borderRadius: BorderRadius.circular(AppTheme.rCard),
                      ),
                      child: Icon(Icons.account_balance_wallet_outlined,
                          size: 22, color: context.colors.accent),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Accounflow', style: context.text.headlineMedium),
                  const SizedBox(height: 4),
                  Text(
                    _isSignUp ? 'Create your account.' : 'Sign in to your books.',
                    style: context.text.bodyMedium
                        ?.copyWith(color: context.colors.textSecondary),
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.mail_outline),
                    ),
                    validator: (v) {
                      final t = (v ?? '').trim();
                      if (t.isEmpty) return 'Enter your email';
                      if (!t.contains('@') || !t.contains('.')) {
                        return 'Enter a valid email';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) {
                      if ((v ?? '').isEmpty) return 'Enter your password';
                      if (_isSignUp && (v ?? '').length < 6) {
                        return 'Use at least 6 characters';
                      }
                      return null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: context.text.labelMedium
                            ?.copyWith(color: context.colors.negative)),
                  ],
                  if (_info != null) ...[
                    const SizedBox(height: 12),
                    Text(_info!,
                        style: context.text.labelMedium
                            ?.copyWith(color: context.colors.positive)),
                  ],
                  const SizedBox(height: 32),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: context.colors.onButtonFill,
                            ),
                          )
                        : Text(_isSignUp ? 'Create account' : 'Sign in'),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.center,
                    child: TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _isSignUp = !_isSignUp;
                                _error = null;
                                _info = null;
                              }),
                      child: Text(_isSignUp
                          ? 'Already have an account? Sign in'
                          : "Don't have an account? Create account"),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
