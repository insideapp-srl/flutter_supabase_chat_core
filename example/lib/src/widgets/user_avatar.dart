import 'package:flutter/material.dart';
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

import '../theme/app_theme.dart';

/// Circular avatar: the image when there is one (loaded with the Supabase
/// auth headers, since chat buckets are private), initials on a stable
/// color otherwise. Optionally shows a live online dot.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.id,
    this.name,
    this.imageUrl,
    this.size = 44,
    this.showOnlineStatus = false,
    this.icon,
  });

  /// Creates an avatar for [user].
  factory UserAvatar.user(
    ChatUser user, {
    double size = 44,
    bool showOnlineStatus = false,
  }) => UserAvatar(
    id: user.id,
    name: user.fullName.isEmpty ? null : user.fullName,
    imageUrl: user.imageUrl,
    size: size,
    showOnlineStatus: showOnlineStatus,
  );

  /// Creates an avatar for [room]: the other member for direct rooms (with
  /// their online status), a group icon otherwise.
  factory UserAvatar.room(
    ChatRoom room,
    String currentUserId, {
    double size = 48,
  }) {
    final other = room.otherUser(currentUserId);
    if (other != null) {
      return UserAvatar(
        id: other.id,
        name: room.name,
        imageUrl: room.imageUrl,
        size: size,
        showOnlineStatus: true,
      );
    }
    return UserAvatar(
      id: room.id,
      name: room.name,
      imageUrl: room.imageUrl,
      size: size,
      icon: Icons.groups_rounded,
    );
  }

  final String id;
  final String? name;
  final String? imageUrl;
  final double size;
  final bool showOnlineStatus;
  final IconData? icon;

  String get _initials {
    final words = (name ?? '').trim().split(RegExp(r'\s+'));
    return words
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = avatarColor(id, scheme);
    final initials = _initials;
    final fallback = Center(
      child: icon != null || initials.isEmpty
          ? Icon(
              icon ?? Icons.person_rounded,
              color: Colors.white,
              size: size * .5,
            )
          : Text(
              initials,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: size * .36,
              ),
            ),
    );

    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, .18)!],
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl == null
          ? fallback
          : Image.network(
              imageUrl!,
              headers: SupabaseChatCore.instance.httpSupabaseHeaders,
              fit: BoxFit.cover,
              width: size,
              height: size,
              errorBuilder: (_, _, _) => fallback,
            ),
    );

    if (!showOnlineStatus) return avatar;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -1,
            bottom: -1,
            child: UserOnlineStatusWidget(
              uid: id,
              builder: (status) => AnimatedScale(
                scale: status == UserOnlineStatus.online ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                child: Container(
                  width: size * .3,
                  height: size * .3,
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E),
                    shape: BoxShape.circle,
                    border: Border.all(color: scheme.surface, width: 2.5),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
