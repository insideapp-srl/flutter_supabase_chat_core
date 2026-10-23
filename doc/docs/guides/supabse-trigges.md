---
id: supabase-triggers
title: Database Triggers
---

`example/utils/sql/02_database_trigger.sql` defines the triggers below. Row-level triggers on the partitioned `chats.messages` apply to every partition automatically (Postgres 13+), so they are defined once on the parent table.

| Trigger | Table | When | Function |
|---------|-------|------|----------|
| `on_auth_user_created` | `auth.users` | after insert | `chats.handle_new_user()` |
| `update_last_messages_trigger` | `chats.messages` | after insert/update/delete | `chats.update_last_messages()` |
| `update_status_before_insert` | `chats.messages` | before insert | `chats.set_message_status_to_sent()` |
| `queue_media_for_deletion_trigger` | `chats.messages` | after delete | `chats.queue_media_for_deletion()` |
| `broadcast_message_change_trigger` | `chats.messages` | after insert/update/delete | `chats.broadcast_message_change()` |
| `delete_room_if_empty_trigger` | `chats.room_members` | after delete, deferred | `chats.delete_room_if_empty()` |

## Handle new user

Creates the chat profile of every new auth user, taking the names and avatar from the sign-up metadata when present (`auth.signUp(data: {'first_name': ..., 'last_name': ..., 'avatar_url': ...})`, also the shape most OAuth providers fill in), so the profile is complete without a second update call:

```sql
CREATE OR REPLACE FUNCTION chats.handle_new_user()
    RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS $BODY$
DECLARE
    meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
BEGIN
    INSERT INTO chats.users (id, "firstName", "lastName", "imageUrl", "createdAt", "updatedAt", "lastSeen")
    VALUES (
        new.id,
        nullif(coalesce(meta ->> 'first_name', meta ->> 'firstName', meta ->> 'given_name'), ''),
        nullif(coalesce(meta ->> 'last_name', meta ->> 'lastName', meta ->> 'family_name'), ''),
        nullif(coalesce(meta ->> 'avatar_url', meta ->> 'picture'), ''),
        now(), now(), now()
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN new;
END;
$BODY$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute procedure chats.handle_new_user();
```

If your app doesn't authenticate with Supabase Auth, replace this trigger with your own way of filling `chats.users` (its `id` must still match `auth.users.id`).

## Update room last message

Keeps `chats.rooms."lastMessages"` in sync with the room's newest message. Only a **new** message bumps `updatedAt`: edits, reactions and read receipts refresh the snapshot but keep the order, otherwise reading a chat would reorder everyone's rooms list. `SECURITY DEFINER` because any member sends messages, but only admins may update `chats.rooms` under RLS.

```sql
CREATE OR REPLACE FUNCTION chats.update_last_messages()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    latest_message jsonb;
    affected_room_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        affected_room_id := OLD."roomId";
    ELSE
        affected_room_id := NEW."roomId";
    END IF;

    SELECT to_jsonb(m)
    INTO latest_message
    FROM chats.messages m
    WHERE m."roomId" = affected_room_id
    ORDER BY m."createdAt" DESC
    LIMIT 1;

    IF latest_message IS DISTINCT FROM (
        SELECT value FROM jsonb_array_elements(
                (SELECT "lastMessages" FROM chats.rooms WHERE id = affected_room_id)
                          ) LIMIT 1
    ) THEN
        UPDATE chats.rooms
        SET "updatedAt" = CASE WHEN TG_OP = 'INSERT' THEN now() ELSE "updatedAt" END,
            "lastMessages" = CASE WHEN latest_message IS NULL
                                  THEN NULL
                                  ELSE jsonb_build_array(latest_message) END
        WHERE id = affected_room_id;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;
```

The room update is what the rooms list listens to over Realtime (see [Room and membership changes](#room-and-membership-changes)).

## Set message status to sent

A new message's server-owned columns, for writes from the API roles (`anon`, `authenticated`; the `SECURITY DEFINER` RPCs and maintenance run as the table owner and are not affected): the status is `sent`, pin and reactions start empty, and `createdAt` is the database's (its default, `clock_timestamp()`). A client value of `createdAt` is only accepted within a few minutes of the server clock: it is the partition key and orders every member's timeline, so a far-future date would stay the room's last message for ever and block pg_partman's maintenance. It is rejected rather than clamped, because a `BEFORE` trigger can't move a row to another partition.

Later statuses come from `chats.mark_room_as_read()`, which flips messages to `seen`.

## Protect message columns

`BEFORE UPDATE`, API roles only: an author (the only one RLS lets update a message) may change its content, nothing else. The id, room, author, `createdAt`, status, reactions, pin and forward origin keep their stored values, and `updatedAt` is set by the database whenever the content changes, so an edit is always visible.

## Message ids

`chats.claim_message_id()` registers every new message id in `chats.message_ids` and releases it when the message is deleted. Ids are supplied by clients (optimistic UI), and the partitioned primary key `(id, "createdAt")` can't make `id` alone unique: the registry does, so a reused id fails with a unique violation (`23505`) instead of creating a second row that the RPCs, deletes and clients addressing messages by id would confuse with the first.

## Attest forward origin

`BEFORE INSERT`, API roles only. A forwarded message's `metadata.forwardedFrom` must name the source (`{"sourceRoomId", "sourceMessageId"}`, see `ChatForwardOrigin.claim`): the trigger reads it with the forwarder's privileges (so it must be a message they can read) and replaces the claim with the source's author, author name and date, or keeps the source's own attested origin when it is itself a forward. Any other value is rejected.

## Queue media for deletion

SQL can't delete objects from the storage backend. When a deleted message's `source` points at one of its own attachments (`.../object/authenticated/chats_assets/<roomId>/<file>`, the message's own room folder, or the room's 1.x numeric folder), the bucket and path are recorded in `chats.media_pending_deletion`, for the `cleanup-media` Edge Function to remove later (see [Usage](supabase-usage.md#media-cleanup)), unless another message still references the same file. `source` is written by the author, and the function deletes with the service role, which bypasses storage RLS: any other URL (another room, another bucket, an external server) is never queued. The message row itself is deleted immediately. `SECURITY DEFINER` because the queue is closed to clients.

## Delete room if empty

A room with no members left is deleted, with its messages. It's a `DEFERRABLE INITIALLY DEFERRED` constraint trigger, so the check happens at commit and never sees an intermediate state of a transaction; `SECURITY DEFINER` because the last member leaving is no longer a member by the time it runs.

```sql
CREATE CONSTRAINT TRIGGER delete_room_if_empty_trigger
    AFTER DELETE ON chats.room_members
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION chats.delete_room_if_empty();
```

## Broadcast message changes

Delivers every message change to the room's private Realtime channel `chats:room:<roomId>`, where `SupabaseChatController` listens. Postgres Changes can't be used for `chats.messages` because it is partitioned (see [Realtime](supabase-realtime.md)).

```sql
CREATE OR REPLACE FUNCTION chats.broadcast_message_change()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    v_room_id uuid := coalesce(NEW."roomId", OLD."roomId");
BEGIN
    BEGIN
        PERFORM realtime.broadcast_changes(
            'chats:room:' || v_room_id::text,
            TG_OP,
            TG_OP,
            'messages',
            'chats',
            NEW,
            OLD
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'chats.broadcast_message_change: % (room %)', SQLERRM, v_room_id;
    END;
    RETURN NULL;
END;
$$;
```

A failure to broadcast never loses the message: it is logged as a `WARNING` and the write goes through. If you change `SupabaseChatCoreConfig.realtimeRoomChannelPrefix`, change the `'chats:room:'` prefix here and in `chats.room_id_from_topic()` too.

## Room and membership changes

Statement-level triggers on `chats.rooms` (`UPDATE`) and `chats.room_members` (`INSERT`, `UPDATE`, `DELETE`), using transition tables, call `chats.send_room_change(room, user, removed)` once per affected member: it sends a `room_change` event (`{roomId, removed}`) on the member's private channel `chats:user:<uid>` with `realtime.send`. Every member hears about room updates, joins, leaves and role changes; a member's own `lastReadAt`/`pinnedAt`/`mutedUntil` changes only reach that member; the user who left or was removed (or whose room was deleted) gets `removed: true`. `SupabaseChatCore.roomsChanges()` and `room(id)` listen to it, and the package closes the room's channels on removal (see [Realtime](supabase-realtime.md#rooms-list)). Failures are reported as `WARNING`s, like the message broadcast. If you change `SupabaseChatCoreConfig.realtimeUserChannelPrefix`, change the `'chats:user:'` prefix here and in `chats.is_own_user_topic()` too.

## Ideas

Triggers are also the natural place for push notifications: e.g. an `AFTER INSERT` trigger on `chats.messages` calling an Edge Function with `pg_net`, skipping the members whose `room_members."mutedUntil"` is in the future.
