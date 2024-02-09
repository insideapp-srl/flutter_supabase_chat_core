---
id: supabase-usage
title: Usage
---

As mentioned in [How it works?](../introduction/supabase-overview.md#how-it-works), you will need to register a user using [Supabase Authentication](https://supabase.com/docs/guides/auth). If you are using Supabase Authentication as your auth provider you don't need to do anything, a trigger will create a new row in the `chat.users` table.

## Update user

You can provide values like `firstName`, `imageUrl` and `lastName` if you're planning to have a screen with all users available for chat.

```dart
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

...
user.firstName: 'John';
user.imageUrl: 'https://i.pravatar.cc/300';
user.lastName: 'Doe';

await SupabaseChatCore.instance.updateUser(user);

```

## Supabase Chat users

You can use the `SupabaseChatCore.instance.users()` stream which will return all registered users with avatars and names.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

class UsersPage extends StatelessWidget {
  const UsersPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<List<types.User>>(
        stream: SupabaseChatCore.instance.users(),
        initialData: const [],
        builder: (context, snapshot) {
          // ...
        },
      ),
    );
  }
}
```

## Starting a chat

When you have access to that `uid` or you have the whole `User` class from the `SupabaseChatCore.instance.users()` stream, you can call either `createRoom` or `createGroupRoom`. For the group, you will need to additionally provide a name and an optional image.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

class UsersPage extends StatelessWidget {
  const UsersPage({Key? key}) : super(key: key);

  void _handlePressed(types.User otherUser, BuildContext context) async {
    final room = await SupabaseChatCore.instance.createRoom(otherUser);
    // Navigate to the Chat screen
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<List<types.User>>(
        stream: SupabaseChatCore.instance.users(),
        initialData: const [],
        builder: (context, snapshot) {
          // ...
        },
      ),
    );
  }
}
```

## Rooms

To render user's rooms you use the `SupabaseChatCore.instance.rooms()` stream. `Room` class will have the name and image URL taken either from provided ones for the group or set to the other person's image URL and name. See [Security Rules](supabase-security-rls.md) for more info about rooms filtering.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

class RoomsPage extends StatelessWidget {
  const RoomsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<List<types.Room>>(
        stream: SupabaseChatCore.instance.rooms(),
        initialData: const [],
        builder: (context, snapshot) {
          // ...
        },
      ),
    );
  }
}
```

## Messages

`SupabaseChatCore.instance.messages` stream will give you access to all messages in the specified room. If you want to have dynamic updates for the room itself, you will need to wrap messages stream with a room stream. See the [example](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/example/lib/chat.dart).

```dart
import 'package:flutter/material.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

class ChatPage extends StatelessWidget {
  const ChatPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<List<types.Message>>(
        initialData: const [],
        stream: SupabaseChatCore.instance.messages(widget.room),
        builder: (context, snapshot) {
          // ...
        },
      ),
    );
  }
}
```

If you use Flyer Chat UI you can just pass `snapshot.data ?? []` to the `messages` parameter of the Chat widget. See the [example](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/example/lib/chat.dart).

### Send a message

To send a message use `SupabaseChatCore.instance.sendMessage`, it accepts 2 parameters:

* Any partial message. Click [here](https://docs.flyer.chat/flutter/chat-ui/types) to learn more about the types or check the [API reference](https://pub.dev/documentation/flutter_chat_types/latest/index.html). You provide a partial message because Supabase will set fields like `authorId`, `createdAt` and `id` automatically.
* Room ID.

### Update the message

To update the message use `SupabaseChatCore.instance.updateMessage`, it accepts 2 parameters:

* Any message. Click [here](https://docs.flyer.chat/flutter/chat-ui/types) to learn more about the types or check the [API reference](https://pub.dev/documentation/flutter_chat_types/latest/index.html). Use a message you get from the `SupabaseChatCore.instance.messages` stream, update it and send as this parameter.
* Room ID.

## `supabaseUser`

`SupabaseChatCore.instance.supabaseUser` is a shortcut you can use to see which user is currently logged in through Supabase Authentication. The returned type comes from the Supabase library and **it is not the same `User` as from the `flutter_chat_types` package**.
