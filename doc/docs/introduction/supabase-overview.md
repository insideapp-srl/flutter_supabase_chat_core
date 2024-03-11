---
id: supabase-overview
title: Overview
slug: /
---

Have you ever wanted to implement a chat in your application? Do you think it's difficult and complex?

Try this, thanks to the magnificent [Supabase](https://supabase.com/) platform and the [Flutter Chat UI](https://pub.dev/packages/flutter_chat_ui) package, you can achieve it in just a few minutes and effortlessly.

---

Flyer Chat is a platform for creating in-app chat experiences using Flutter or React Native. This is the documentation for Supabase BaaS implementation for Flutter.

## How it works?

We use [Supabase](https://supabase.com/docs) as the backend. There we have three tables, `rooms`, `messages` and `users`. Let's break them down:

* `rooms` table contains all conversations in your app. [Postgres Row Security Level](https://supabase.com/docs/guides/database/postgres/row-level-security) are responsible for showing only those rooms where the user's in. The room contains some metadata, a participants list and other room information.
* `messages` table contains all messages in your app. [Postgres Row Security Level](https://supabase.com/docs/guides/database/postgres/row-level-security) are responsible for showing only those messages of the rooms where the user's in. The massage contains all message data.
* `users` table contains users data, such as avatars and names. You can use this collection to render a list of users available for chat. This table is populate automatically by trigger.

Both array of participant IDs in the `room` and rows in `users` tables use `User UID` from [Supabase Authentication](https://supabase.com/docs/guides/auth) as an ID, for easier navigation through the data. That means every user of the chat should be registered using Supabase's authentication module, but if your app doesn't use Supabase as an authentication provider, you still can register in Supabase by providing your `JWT` token, so you can have your backend working together with a chat on Supabase (in this case it will be necessary to remove the trigger that inserts users).

[Postgres Triggers](https://supabase.com/docs/guides/database/postgres/triggers) can be used for setting message's statuses and for triggering push notifications. In this documentation, you will see an [example](../guides/supabse-trigges.md) of setting `delivered` message status.

[Supabase Storage](https://supabase.com/docs/guides/storage) can be used as a storage provider for images and files.

## Motivation

Ever estimated a simple chat for weeks of work? Didn't want to start because it is always the same boring work for an extended period of time? Was it moved to post MVP because of lack of time and resources? Were you left with a frustrated client, who couldn't understand why the thing that exists in almost every app takes that much time to implement?

We are trying to solve all this by working on a Flyer Chat.

You will say that there are libraries out there that will help create chats, but we are working on a more complete solution - very similar on completely different platforms like React Native and Flutter (we don't always work in just one) with an optional Supabase BaaS, since chat is not only UI. We are making this free and open-source so together we can create a product that works for everyone.
