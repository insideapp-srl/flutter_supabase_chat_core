---
id: supabase-realtime
title: Realtime
---

The package uses [Supabase Realtime](https://supabase.com/docs/guides/realtime) Broadcast and Presence, always on **private** channels authorized by RLS policies on `realtime.messages`:

| Data | Feature | Channel | Who receives | Who sends |
|------|---------|---------|--------------|-----------|
| Message inserts, updates, deletes | Broadcast from Database | `chats:room:<roomId>` | room members | the database only |
| Typing indicator | Broadcast (client to client) | `chats:room:<roomId>:typing` | room members | room members |
| Rooms list (`roomsChanges()`, `SupabaseChatRoomsController`) and single room (`room(id)`) | Broadcast from Database | `chats:user:<uid>` | that user only | the database only |
| Online status | Presence | `online-user-<uid>` | any signed-in user | that user only |

Postgres Changes are not used: `chats.messages` is partitioned (see below), and Realtime doesn't apply RLS to `DELETE` events, so publishing `chats.rooms`/`chats.room_members` told every subscriber who left which room. `01_database_schema.sql` removes those tables from the `supabase_realtime` publication.

## Room channels

Every message change is sent to the room's channel by the `chats.broadcast_message_change` trigger, which calls `realtime.broadcast_changes` with the operation (`INSERT`, `UPDATE`, `DELETE`) as event name and the new and old rows as payload. `SupabaseChatController` listens to those events and applies them to its list.

Why not Postgres Changes on `chats.messages`:

* `chats.messages` is partitioned, and Postgres Changes reports each row under the partition it physically lives in (`chats.messages_p20261019`, ...), so a subscription on the parent table never matches anything;
* Broadcast authorizes once, when the channel is joined, instead of evaluating RLS for every change and every subscriber;
* a `DELETE` broadcast carries the whole old row, so it can be routed to its room.

Members can't send on the message channel: every event on it comes from the database, so a member can't make other members' apps show a message that was never stored, rewrite someone else's message or hide one. The typing indicator, the only thing clients send, has its own `chats:room:<roomId>:typing` channel.

A failure to broadcast never loses the message: the trigger reports it as a Postgres `WARNING` and the write goes through.

Requirements: Realtime with Broadcast from Database support (Supabase cloud, or self-hosted `supabase/realtime` >= v2.33).

### Authorization

Realtime authorizes joining a private channel (receiving broadcasts and presence) against `SELECT` policies on `realtime.messages`, and sending (broadcast, presence tracking) against `INSERT` policies. `03_database_policy.sql` creates them:

```sql
CREATE POLICY "chats.realtime_room_read"
    ON realtime.messages
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING (
        chats.is_chat_member_topic((SELECT realtime.topic()))
        OR chats.is_own_user_topic((SELECT realtime.topic()))
        OR chats.is_presence_topic((SELECT realtime.topic()))
    );

CREATE POLICY "chats.realtime_room_write"
    ON realtime.messages
    AS PERMISSIVE
    FOR INSERT
    TO authenticated
    WITH CHECK (
        (extension = 'broadcast' AND chats.is_chat_typing_topic((SELECT realtime.topic())))
        OR (extension = 'presence' AND chats.is_own_presence_topic((SELECT realtime.topic())))
    );
```

The helpers only match the topic shapes above with a valid uuid, so policies other apps define on `realtime.messages` are unaffected and malformed topics are simply refused.

### Sharing and lifecycle

Realtime allows a single join per topic per connection, so a `SupabaseChatCore` keeps one pair of channels per room (messages and typing), shared by every controller open on it, and releases them when the last one is disposed. When Realtime refuses a channel as unauthorized the channels are released and not retried, instead of rejoining with backoff for as long as the connection lives; the controller reports the failure through `onError`.

Realtime checks a private channel's policies when it is joined. So that a member removed from a room doesn't keep receiving its messages on an already open channel, the database tells the removed user on their user channel (`removed: true`, see below) and the package closes the room's channels right away, reporting it to the controllers through `onError`. A client that ignores that event keeps the channel until Realtime re-authorizes it (on a new join or token refresh): keep the JWT expiry short if that window matters to you.

Everything above belongs to the signed-in user's session. `closeSession()`, a sign out or a switch to another user removes the room channels, the user channel, the presence watches and the subscriptions behind `room(id)`, `roomsChanges()` and `userOnlineStatus()`, whose streams complete. Call `closeSession()` before signing out: once signed out, Realtime is re-authorized with the anon key and private channels would fail instead of leaving cleanly. Auth state changes arrive in bursts (initial session, signed in, token refreshed) and are handled one at a time, so the own presence channel is opened once; status callbacks of channels already released are ignored.

## Typing indicator

The typing indicator used Realtime Presence up to 1.x. Supabase rate-limits Presence `track()` calls per client and drops the channel when the limit is exceeded, which a typing indicator updating every few hundred milliseconds hits within seconds ([issue #38](https://github.com/insideapp-srl/flutter_supabase_chat_core/issues/38)). Since 2.x it uses Broadcast events on the room's typing channel, which are cheap and ephemeral.

The protocol, per user:

* while typing, a `typing` event with `{uid, typing: true}` at most once every **2 seconds** (`onTyping()` can be called on every keystroke);
* a `{uid, typing: false}` event after **3 seconds** without keystrokes, when a message is sent, or when the last controller of the room is disposed;
* receivers drop a user who hasn't sent `typing: true` within **5 seconds**, so a lost "stopped" event (app killed, connection lost) can never leave a stale indicator behind.

The `uid` of a typing event is chosen by the sending member (Broadcast doesn't tell receivers who sent an event): treat it as display data only.

Trade-off: Broadcast keeps no state. Someone opening a room while another member is already typing sees the indicator only from that member's next event, at most 2 seconds later.

## Rooms list

Room and membership changes reach each member on their own user channel `chats:user:<uid>`, which only that user may join. Statement-level triggers on `chats.rooms` and `chats.room_members` call `chats.send_room_change`, which sends a `room_change` event with `{roomId, removed}`:

* to every member of a room when the room is updated (e.g. a new message updates its `lastMessages` and `updatedAt`), someone joins or leaves it, or a role changes;
* only to the member concerned when their own per-member columns change (`lastReadAt`, `pinnedAt`, `mutedUntil`);
* with `removed: true` to the user who left, was removed, or whose room was deleted.

`roomsChanges()` refetches the room from `chats.rooms_l` on each event (so the unread count and the caller's preferences are fresh) and emits a `ChatRoomUpserted`, or a `ChatRoomRemoved` when `removed` is true or the room is no longer visible; `room(id)` refetches it and completes when it's gone. Rooms rejected by `SupabaseChatCoreConfig.roomFilter` are skipped. A failed or timed-out subscription is surfaced as a `SupabaseChatCoreRequestException` on the stream.

## Online status

`UserOnlineStateObserver` tracks the logged-in user on the private Presence channel `online-user-<uid>` while the app is in the foreground and untracks it otherwise; going offline also stores `chats.users."lastSeen"`. `userOnlineStatus(uid)` (and `UserOnlineStatusWidget`) listen to that channel: every listener of the same user shares one channel, closed when the last listener cancels, and the stream emits the current status first.

Any signed-in user may watch anyone's status, like profiles, which every signed-in user can read; only the user themselves may publish on their channel, so nobody can make someone else appear online, and the anon key alone can't watch anyone. Restrict `chats.is_presence_topic` (`03_database_policy.sql`) if your app needs a narrower audience. The policies match the default `realtimeOnlineUserPrefixChannel` (`online-user-`): update them if you change it.

## Self-hosted notes

* `supabase db reset` (or restoring a database) restarts Postgres but not Realtime, which can then stay in a degraded state and silently stop delivering events: restart the Realtime container afterwards. `tool/local_db.sh` does it for the local stack.
* Private channels need Realtime's authorization enabled (the default on Supabase); with "Allow public access" disabled, clients can only use the private channels above.
* `chats.users` and `chats.messages` stay in the `supabase_realtime` publication for apps that use them; the package itself doesn't subscribe to Postgres Changes.
