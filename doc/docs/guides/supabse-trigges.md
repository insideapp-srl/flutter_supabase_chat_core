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

The room update is what the rooms list listens to over Realtime (Postgres Changes on `chats.rooms`).

## Set message status to sent

```sql
CREATE OR REPLACE FUNCTION chats.set_message_status_to_sent()
    RETURNS TRIGGER
    SET search_path = ''
AS $$
BEGIN
    NEW.status := 'sent';
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

Later statuses come from `chats.mark_room_as_read()`, which flips messages to `seen`.

## Queue media for deletion

SQL can't delete objects from the storage backend. When a deleted message's `source` points at Supabase Storage (`.../object/authenticated/<bucket>/<path>`), the bucket and path are recorded in `chats.media_pending_deletion`, for the `cleanup-media` Edge Function to remove later (see [Usage](supabase-usage.md#media-cleanup)). The message row itself is deleted immediately. `SECURITY DEFINER` because the queue is closed to clients.

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

A failure to broadcast never loses the message: it is logged as a `WARNING` and the write goes through. If you change `SupabaseChatCoreConfig.realtimeRoomChannelPrefix`, change the `'chats:room:'` prefix here and in `chats.is_chat_member_topic()` too.

## Ideas

Triggers are also the natural place for push notifications: e.g. an `AFTER INSERT` trigger on `chats.messages` calling an Edge Function with `pg_net`, skipping the members whose `room_members."mutedUntil"` is in the future.
