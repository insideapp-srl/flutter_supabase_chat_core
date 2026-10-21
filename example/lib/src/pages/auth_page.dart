import 'package:faker/faker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Sign in / sign up. First and last name go into the sign-up metadata,
/// which the `chats.handle_new_user` trigger copies into the chat profile.
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  bool _signUp = false;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _firstName.dispose();
    _lastName.dispose();
    super.dispose();
  }

  void _fillDemoAccount() {
    final faker = Faker();
    final first = faker.person.firstName();
    final last = faker.person.lastName();
    setState(() {
      _signUp = true;
      _firstName.text = first;
      _lastName.text = last;
      _email.text =
          '${first.toLowerCase()}.${last.toLowerCase()}${faker.randomGenerator.integer(999)}@example.com';
      _password.text = 'Demo-password-1';
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final auth = Supabase.instance.client.auth;
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_signUp) {
        final response = await auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          data: {
            'first_name': _firstName.text.trim(),
            'last_name': _lastName.text.trim(),
          },
        );
        if (response.session == null) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Check your inbox to confirm your email.'),
            ),
          );
        }
      } else {
        await auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
    } on AuthException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer,
              scheme.surface,
              scheme.tertiaryContainer,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  spacing: 24,
                  children: [
                    _Logo(scheme: scheme),
                    Column(
                      spacing: 6,
                      children: [
                        Text(
                          'Supabase Chat',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Realtime chat on Supabase + Flyer Chat',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    Card(
                      elevation: 0,
                      color: scheme.surface.withValues(alpha: .85),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Form(
                          key: _formKey,
                          child: AutofillGroup(
                            child: Column(
                              spacing: 14,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SegmentedButton<bool>(
                                  segments: const [
                                    ButtonSegment(
                                      value: false,
                                      label: Text('Sign in'),
                                    ),
                                    ButtonSegment(
                                      value: true,
                                      label: Text('Create account'),
                                    ),
                                  ],
                                  selected: {_signUp},
                                  showSelectedIcon: false,
                                  onSelectionChanged: (s) =>
                                      setState(() => _signUp = s.first),
                                ),
                                AnimatedSize(
                                  duration: const Duration(milliseconds: 250),
                                  curve: Curves.easeOutCubic,
                                  child: _signUp
                                      ? Row(
                                          spacing: 12,
                                          children: [
                                            Expanded(
                                              child: TextFormField(
                                                controller: _firstName,
                                                textCapitalization:
                                                    TextCapitalization.words,
                                                autofillHints: const [
                                                  AutofillHints.givenName,
                                                ],
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: 'First name',
                                                    ),
                                                validator: _required,
                                              ),
                                            ),
                                            Expanded(
                                              child: TextFormField(
                                                controller: _lastName,
                                                textCapitalization:
                                                    TextCapitalization.words,
                                                autofillHints: const [
                                                  AutofillHints.familyName,
                                                ],
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: 'Last name',
                                                    ),
                                              ),
                                            ),
                                          ],
                                        )
                                      : const SizedBox(width: double.infinity),
                                ),
                                TextFormField(
                                  controller: _email,
                                  keyboardType: TextInputType.emailAddress,
                                  autofillHints: const [AutofillHints.email],
                                  decoration: const InputDecoration(
                                    labelText: 'Email',
                                    prefixIcon: Icon(Icons.alternate_email),
                                  ),
                                  validator: (v) => v != null && v.contains('@')
                                      ? null
                                      : 'Enter a valid email',
                                ),
                                TextFormField(
                                  controller: _password,
                                  obscureText: _obscure,
                                  autofillHints: [
                                    _signUp
                                        ? AutofillHints.newPassword
                                        : AutofillHints.password,
                                  ],
                                  decoration: InputDecoration(
                                    labelText: 'Password',
                                    prefixIcon: const Icon(Icons.lock_outline),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _obscure
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                      ),
                                      onPressed: () =>
                                          setState(() => _obscure = !_obscure),
                                    ),
                                  ),
                                  validator: (v) => v != null && v.length >= 6
                                      ? null
                                      : 'At least 6 characters',
                                  onFieldSubmitted: (_) => _submit(),
                                ),
                                const SizedBox(height: 4),
                                FilledButton(
                                  onPressed: _busy ? null : _submit,
                                  child: _busy
                                      ? const SizedBox.square(
                                          dimension: 22,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2.5,
                                          ),
                                        )
                                      : Text(
                                          _signUp
                                              ? 'Create account'
                                              : 'Sign in',
                                        ),
                                ),
                                TextButton.icon(
                                  onPressed: _busy ? null : _fillDemoAccount,
                                  icon: const Icon(Icons.auto_awesome_outlined),
                                  label: const Text('Fill in a demo account'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => Container(
    width: 88,
    height: 88,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [scheme.primary, scheme.tertiary],
      ),
      boxShadow: [
        BoxShadow(
          color: scheme.primary.withValues(alpha: .35),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: Icon(Icons.forum_rounded, size: 46, color: scheme.onPrimary),
  );
}
