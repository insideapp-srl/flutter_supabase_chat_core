---
id: supabase-realtime
title: Realtime
---

The package uses all three [Supabase Realtime](https://supabase.com/docs/guides/realtime) features, each where it fits best:

| Data | Feature | Channel |
|------|---------|---------|
| Message inserts, updates, deletes | Broadcast from Database | private `chats:room:<roomId>` |
| Typing indicator | Broadcast (client to client) | same private channel |
| Rooms list (`roomsChanges()`, `SupabaseChatRoomsController`) and single room (`room(id)`) | Postgres Changes on `chats.rooms` and `chats.room_members` | one per subscription |
| Online status | Presence | `online-user-<uid>` |

## Room channels

Every message change is sent to the room's private channel by the `chats.broadcast_message_change` trigger, which calls `realtime.broadcast_changes` with the operation (`INSERT`, `UPDATE`, `DELETE`) as event name and the new and old rows as payload. `SupabaseChatController` listens to those events and applies them to its list.

Why not Postgres Changes on `chats.messages`:

* `chats.messages` is partitioned, and Postgres Changes reports each row under the partition it physically lives in (`chats.messages_p20261019`, ...), so a subscription on the parent table never matches anything;
* Broadcast authorizes once, when the channel is joined, instead of evaluating RLS for every change and every subscriber;
* a `DELETE` broadcast carries the whole old row, so it can be routed to its room.

A failure to broadcast never loses the message: the trigger reports it as a Postgres `WARNING` and the write goes through.

Requirements: Realtime with Broadcast from Database support (Supabase cloud, or self-hosted `supabase/realtime` >= v2.33).

### Authorization

Room channels are private (`RealtimeChannelConfig(private: true)`). Realtime authorizes them against RLS policies on `realtime.messages`, created by `03_database_policy.sql`:

```sql
CREATE POLICY "chats.realtime_room_read"
    ON realtime.messages
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING (chats.is_chat_member_topic((SELECT realtime.topic())));

CREATE POLICY "chats.realtime_room_write"
    ON realtime.messages
    AS PERMISSIVE
    FOR INSERT
    TO authenticated
    WITH CHECK (
        extension = 'broadcast'
        AND chats.is_chat_member_topic((SELECT realtime.topic()))
    );
```

`chats.is_chat_member_topic` only matches topics starting with `chats:room:` followed by a valid uuid, so policies other apps define on `realtime.messages` are unaffected and malformed topics are simply refused.

### Sharing and lifecycle

Realtime allows a single join per topic per connection, so a `SupabaseChatCore` keeps one channel per room, shared by every controller open on it, and releases it when the last one is disposed. When Realtime refuses a channel as unauthorized (the user isn't, or is no longer, a member) the channel is released and not retried, instead of rejoining with backoff for as long as the connection lives; the controller reports the failure through `onError`.

The Postgres Changes subscriptions behind `room(id)` and `roomsChanges()` use a unique topic per subscription, so several listeners of the same data can coexist. A failed or timed-out subscription is surfaced as a `SupabaseChatCoreRequestException` on the stream.

Everything above belongs to the signed-in user's session. `closeSession()`, a sign out or a switch to another user removes the room channels, the presence watches and the subscriptions behind `room(id)`, `roomsChanges()` and `userOnlineStatus()`, whose streams complete. Call `closeSession()` before signing out: once signed out, Realtime is re-authorized with the anon key and private room channels would fail instead of leaving cleanly. Auth state changes arrive in bursts (initial session, signed in, token refreshed) and are handled one at a time, so the own presence channel is opened once; status callbacks of channels already released are ignored.

## Typing indicator

The typing indicator used Realtime Presence up to 1.x. Supabase rate-limits Presence `track()` calls per client and drops the channel when the limit is exceeded, which a typing indicator updating every few hundred milliseconds hits within seconds ([issue #38](https://github.com/insideapp-srl/flutter_supabase_chat_core/issues/38)). Since 2.x it uses Broadcast events on the room channel, which are cheap and ephemeral.

The protocol, per user:

* while typing, a `typing` event with `{uid, typing: true}` at most once every **2 seconds** (`onTyping()` can be called on every keystroke);
* a `{uid, typing: false}` event after **3 seconds** without keystrokes, when a message is sent, or when the last controller of the room is disposed;
* receivers drop a user who hasn't sent `typing: true` within **5 seconds**, so a lost "stopped" event (app killed, connection lost) can never leave a stale indicator behind.

Trade-off: Broadcast keeps no state. Someone opening a room while another member is already typing sees the indicator only from that member's next event, at most 2 seconds later.

## Rooms list

`roomsChanges()` subscribes to:

* `UPDATE`/`DELETE` on `chats.rooms` (a new message updates the room's `lastMessages` and `updatedAt`);
* `INSERT` on `chats.room_members` for the current user (added to a room);
* `DELETE` on `chats.room_members` (the current user left or was removed, or another member left).

Each relevant event refetches the room from `chats.rooms_l` (so the unread count and the caller's preferences are fresh) and emits a `ChatRoomUpserted`, or a `ChatRoomRemoved` when the room is gone or no longer visible. Rooms rejected by `SupabaseChatCoreConfig.roomFilter` are skipped. Postgres Changes still checks RLS, so users only receive events about rooms they can read.

## Online status

`UserOnlineStateObserver` tracks the logged-in user on the Presence channel `online-user-<uid>` while the app is in the foreground and untracks it otherwise; going offline also stores `chats.users."lastSeen"`. `userOnlineStatus(uid)` (and `UserOnlineStatusWidget`) listen to that channel: every listener of the same user shares one channel, closed when the last listener cancels, and the stream emits the current status first.

## Self-hosted notes

* `supabase db reset` (or restoring a database) restarts Postgres but not Realtime, whose Postgres Changes poller can stay in a degraded state and silently stop delivering events: restart the Realtime container afterwards. `tool/local_db.sh` does it for the local stack.
* `chats.rooms`, `chats.room_members`, `chats.users` and `chats.messages` are added to the `supabase_realtime` publication by `01_database_schema.sql`.
