import 'package:flutter/material.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app.dart';
import '../widgets/user_avatar.dart';

/// Own profile: avatar, name, theme and sign out.
class ProfileSheet extends StatefulWidget {
  const ProfileSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const ProfileSheet(),
  );

  @override
  State<ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<ProfileSheet> {
  final _chat = SupabaseChatCore.instance;
  late final _firstName = TextEditingController(
    text: _chat.loggedUser?.firstName,
  );
  late final _lastName = TextEditingController(
    text: _chat.loggedUser?.lastName,
  );
  bool _saving = false;

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String error) async {
    setState(() => _saving = true);
    try {
      await action();
    } on SupabaseChatCoreException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error: ${e.cause ?? e}')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickAvatar() async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (image == null) return;
    final bytes = await image.readAsBytes();
    await _run(
      () => _chat.uploadUserAvatar(image.name, bytes),
      'Cannot update the avatar',
    );
  }

  Future<void> _save() => _run(() async {
    final user = _chat.loggedUser;
    if (user == null) return;
    await _chat.updateUser(
      user.copyWith(
        firstName: _firstName.text.trim(),
        lastName: _lastName.text.trim(),
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }, 'Cannot save the profile');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = _chat.loggedUser;
    final email = Supabase.instance.client.auth.currentUser?.email ?? '';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          Stack(
            children: [
              if (user != null) UserAvatar.user(user, size: 96),
              Positioned(
                right: 0,
                bottom: 0,
                child: IconButton.filled(
                  onPressed: _saving ? null : _pickAvatar,
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                ),
              ),
            ],
          ),
          Text(email, style: theme.textTheme.bodyMedium),
          Row(
            spacing: 12,
            children: [
              Expanded(
                child: TextField(
                  controller: _firstName,
                  decoration: const InputDecoration(labelText: 'First name'),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _lastName,
                  decoration: const InputDecoration(labelText: 'Last name'),
                ),
              ),
            ],
          ),
          ValueListenableBuilder(
            valueListenable: themeMode,
            builder: (context, mode, _) => SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Dark'),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (s) => themeMode.value = s.first,
            ),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
          TextButton.icon(
            onPressed: () async {
              Navigator.of(context).pop();
              await Supabase.instance.client.auth.signOut();
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
          ),
        ],
      ),
    );
  }
}
