import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'pages/auth_page.dart';
import 'pages/home_page.dart';
import 'theme/app_theme.dart';

/// App-wide theme mode, switched from the profile sheet.
final themeMode = ValueNotifier(ThemeMode.system);

class ChatExampleApp extends StatelessWidget {
  const ChatExampleApp({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: themeMode,
    builder: (context, mode, _) => MaterialApp(
      title: 'Supabase Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
      home: const UserOnlineStateObserver(child: AuthGate()),
    ),
  );
}

/// Shows [AuthPage] or [HomePage] depending on the auth state.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final StreamSubscription<AuthState> _subscription;
  Session? _session = Supabase.instance.client.auth.currentSession;
  bool _profileReady = false;

  @override
  void initState() {
    super.initState();
    _subscription = Supabase.instance.client.auth.onAuthStateChange.listen(
      (data) => _onSession(data.session),
      onError: (Object error) {
        if (mounted) setState(() => _session = null);
      },
    );
    _onSession(_session);
  }

  Future<void> _onSession(Session? session) async {
    final changedUser = session?.user.id != _session?.user.id;
    setState(() {
      _session = session;
      if (changedUser || session == null) _profileReady = false;
    });
    if (session == null || _profileReady) return;
    try {
      final profile = await SupabaseChatCore.instance.refreshLoggedUser();
      if (profile == null) {
        // A valid session without a chat profile: the account was deleted
        // (or the database reset). Start over from the sign-in page.
        await Supabase.instance.client.auth.signOut();
        return;
      }
    } on SupabaseChatCoreException {
      // The home page works without a cached profile (it's only used for
      // the own avatar); the next auth event retries.
    }
    if (mounted && _session?.user.id == session.user.id) {
      setState(() => _profileReady = true);
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 350),
    child: _session == null
        ? const AuthPage()
        : !_profileReady
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : HomePage(key: ValueKey(_session!.user.id)),
  );
}
