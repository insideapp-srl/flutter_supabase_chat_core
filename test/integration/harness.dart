import 'dart:async';
import 'dart:io';

import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Connection settings, from the environment (see tool/test_integration.sh).
final supabaseUrl = Platform.environment['CHAT_TEST_SUPABASE_URL'];
final anonKey = Platform.environment['CHAT_TEST_ANON_KEY'];
final serviceRoleKey = Platform.environment['CHAT_TEST_SERVICE_ROLE_KEY'];

/// Reason to skip the integration suite, or `null` when it can run.
String? get skipReason =>
    supabaseUrl == null || anonKey == null || serviceRoleKey == null
    ? 'CHAT_TEST_SUPABASE_URL / CHAT_TEST_ANON_KEY / '
          'CHAT_TEST_SERVICE_ROLE_KEY not set: run tool/test_integration.sh'
    : null;

/// A signed-in test user with its own Supabase client and chat core.
class TestUser {
  TestUser._(this.client, this.chat, this.id, this.firstName, this.lastName);

  /// Creates a confirmed auth user through the admin API (names go into the
  /// sign-up metadata, like the example app does), then signs it in on a
  /// dedicated client.
  static Future<TestUser> create(
    String firstName,
    String lastName, {
    SupabaseChatCoreConfig config = const SupabaseChatCoreConfig(),
  }) async {
    final email =
        '${firstName.toLowerCase()}.${const Uuid().v4().substring(0, 8)}@test.dev';
    const password = 'Test-password-1';
    final admin = SupabaseClient(supabaseUrl!, serviceRoleKey!);
    try {
      await admin.auth.admin.createUser(
        AdminUserAttributes(
          email: email,
          password: password,
          emailConfirm: true,
          userMetadata: {'first_name': firstName, 'last_name': lastName},
        ),
      );
    } finally {
      await admin.dispose();
    }

    final client = SupabaseClient(
      supabaseUrl!,
      anonKey!,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    final auth = await client.auth.signInWithPassword(
      email: email,
      password: password,
    );
    final chat = SupabaseChatCore(client: client, config: config);
    final user = TestUser._(
      chat.client,
      chat,
      auth.user!.id,
      firstName,
      lastName,
    );
    // A freshly issued JWT can be rejected for a second or two as "issued
    // in the future" when the Docker VM clock drifts from the host's.
    await eventually(() async {
      try {
        await chat.refreshLoggedUser();
        return true;
      } on SupabaseChatCoreRequestException {
        return false;
      }
    }, reason: 'first authenticated request never succeeded');
    return user;
  }

  /// Supabase client signed in as this user.
  final SupabaseClient client;

  /// Chat core bound to [client].
  final SupabaseChatCore chat;

  /// Auth user id.
  final String id;

  /// First name given at sign-up.
  final String firstName;

  /// Last name given at sign-up.
  final String lastName;

  /// This user as a [ChatUser].
  ChatUser get asChatUser =>
      ChatUser(id: id, firstName: firstName, lastName: lastName);

  /// Releases the chat core and client.
  Future<void> dispose() async {
    await chat.dispose();
    await client.removeAllChannels();
    await client.realtime.disconnect();
    await client.dispose();
  }
}

/// Polls [condition] until it holds, failing after [timeout].
Future<void> eventually(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (await condition()) return;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(reason ?? 'condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Waits until Realtime has joined every channel of [client] (postgres
/// changes subscriptions only start delivering once joined), plus a short
/// settle time for the server to attach the replication stream.
Future<void> realtimeReady(SupabaseClient client) async {
  await eventually(
    // ignore: invalid_use_of_internal_member
    () => client.getChannels().every((c) => c.isJoined),
    reason: 'realtime channels not joined',
  );
  await Future<void>.delayed(const Duration(seconds: 2));
}
