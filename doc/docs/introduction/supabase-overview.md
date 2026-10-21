---
id: supabase-overview
title: Overview
slug: /
---

Have you ever wanted to implement a chat in your application? Do you think it's difficult and complex?

Try this, thanks to the magnificent [Supabase](https://supabase.com/) platform and the [Flutter Chat UI](https://pub.dev/packages/flutter_chat_ui) package, you can achieve it in just a few minutes and effortlessly.

![Demo: real-time messages, reactions, replies and voice messages](/img/demo.gif)

---

Flyer Chat is a platform for creating in-app chat experiences using Flutter. This is the documentation of `flutter_supabase_chat_core`, the [Supabase](https://supabase.com/docs) backend for [`flutter_chat_core`](https://pub.dev/packages/flutter_chat_core) and [`flutter_chat_ui`](https://pub.dev/packages/flutter_chat_ui) 2.x.

:::info
Coming from 1.x (`flutter_chat_types`)? 2.0 changes both the Dart API and the database schema: read [MIGRATION.md](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/MIGRATION.md).
:::

## How it works

Everything lives in a dedicated `chats` Postgres schema, protected by [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security):

* `chats.users` holds the chat profiles (names, avatar, last seen). A row is created by a trigger for every Supabase Auth user, so every chat user must be registered with [Supabase Authentication](https://supabase.com/docs/guides/auth) (or a third-party auth provider configured in Supabase) and `chats.users.id` matches `auth.users.id`.
* `chats.rooms` holds the conversations: `direct` (1-to-1) or `group`, with a name, an avatar, custom metadata and a snapshot of the last message.
* `chats.room_members` links users to rooms, with a per-room `role` (`admin`, `moderator` or none) and the member's own state: when they last read the room, whether they pinned or muted it.
* `chats.messages` holds the messages, with the same field names as `flutter_chat_core`'s `Message`. It is partitioned by week to stay fast as history grows.

Two views, `chats.rooms_l` and `chats.messages_l`, are what the client reads: `rooms_l` adds the members, the caller's unread count and preferences, and the other member's name for direct rooms.

Writes that touch other people's rows (creating a room with its members, read receipts, reactions, pins) go through `SECURITY DEFINER` functions that check membership themselves. See [Security Rules](../guides/supabase-security-rls.md).

[Supabase Realtime](https://supabase.com/docs/guides/realtime) keeps the UI live: message changes travel on a private Broadcast channel per room, sent by a database trigger; the rooms list follows Postgres Changes; online status uses Presence. See [Realtime](../guides/supabase-realtime.md).

[Supabase Storage](https://supabase.com/docs/guides/storage) holds attachments (`chats_assets`, one folder per room) and avatars (`chats_user_avatar`, one folder per user), both private buckets.

On the Flutter side, the package provides:

* `SupabaseChatCore`: rooms, members, users, messages, uploads and presence;
* `SupabaseChatRoomsController`: a live, paginated rooms list;
* `SupabaseChatController`: a `flutter_chat_core` `ChatController` for one room, to pass to `flutter_chat_ui`'s `Chat`;
* `UserOnlineStateObserver` and `UserOnlineStatusWidget` for online status.

## Motivation

Ever estimated a simple chat for weeks of work? Didn't want to start because it is always the same boring work for an extended period of time? Was it moved to post MVP because of lack of time and resources? Were you left with a frustrated client, who couldn't understand why the thing that exists in almost every app takes that much time to implement?

We are trying to solve all this by working on a Flyer Chat.

You will say that there are libraries out there that will help create chats, but we are working on a more complete solution - very similar on completely different platforms like React Native and Flutter (we don't always work in just one) with an optional Supabase BaaS, since chat is not only UI. We are making this free and open-source so together we can create a product that works for everyone.
