
-- Creates the chat profile of every new auth user. First/last name and
-- avatar are taken from the sign-up metadata when present
-- (`auth.signUp(data: {'first_name': ..., 'last_name': ..., 'avatar_url': ...})`,
-- also the shape most OAuth providers fill in), so a profile is complete
-- from the start without a second, separately-authorized update call.
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


-- Keeps chats.rooms."lastMessages"/"updatedAt" in sync with the room's
-- newest message. SECURITY DEFINER: any member sends messages, but only
-- room admins may update chats.rooms under RLS.
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
        -- Only a new message moves the room up the list: edits, reactions
        -- and read receipts (status -> seen) refresh the snapshot but keep
        -- "updatedAt", or merely reading a chat would reorder everyone's
        -- rooms list.
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


drop trigger if exists update_last_messages_trigger on chats.messages;
CREATE TRIGGER update_last_messages_trigger
    AFTER INSERT OR UPDATE OR DELETE ON chats.messages
    FOR EACH ROW
EXECUTE FUNCTION chats.update_last_messages();

CREATE OR REPLACE FUNCTION chats.set_message_status_to_sent()
    RETURNS TRIGGER
    SET search_path = ''
AS $$
BEGIN
    NEW.status := 'sent';
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

drop trigger if exists update_status_before_insert on chats.messages;
CREATE TRIGGER update_status_before_insert
    BEFORE INSERT ON chats.messages
    FOR EACH ROW EXECUTE FUNCTION chats.set_message_status_to_sent();

-- A message's storage media (its `source`, when it points at the
-- chats_assets bucket) can't be deleted by SQL alone -- the storage backend
-- needs a real API call. Instead, record the bucket/path here for the
-- cleanup-media Edge Function (see supabase/functions/cleanup-media) to
-- pick up and remove later, whenever a message referencing one is deleted.
-- Deleting the message row itself still happens immediately, same as today.
-- SECURITY DEFINER: chats.media_pending_deletion is closed to clients.
CREATE OR REPLACE FUNCTION chats.queue_media_for_deletion()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    marker text := '/object/authenticated/';
    idx int;
    rest text;
    slash_idx int;
BEGIN
    IF OLD.source IS NOT NULL THEN
        idx := position(marker IN OLD.source);
        IF idx > 0 THEN
            rest := substring(OLD.source FROM idx + char_length(marker));
            slash_idx := position('/' IN rest);
            IF slash_idx > 0 THEN
                INSERT INTO chats.media_pending_deletion ("bucketId", path)
                VALUES (
                    substring(rest FROM 1 FOR slash_idx - 1),
                    substring(rest FROM slash_idx + 1)
                );
            END IF;
        END IF;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- Row-level triggers on a partitioned parent apply to all of its
-- partitions automatically (PG13+, unlike the RLS-enabled flag -- see the
-- note in 01_database_schema.sql), so this needs to be defined only once
-- here on chats.messages, not per-partition.
drop trigger if exists queue_media_for_deletion_trigger on chats.messages;
CREATE TRIGGER queue_media_for_deletion_trigger
    AFTER DELETE ON chats.messages
    FOR EACH ROW EXECUTE FUNCTION chats.queue_media_for_deletion();

-- A room with zero members left is deleted automatically. This must be a
-- DEFERRED constraint trigger (checked at transaction commit, not
-- immediately after each row delete): chats.replace_room_members()
-- (03_database_policy.sql) deletes every existing member row before
-- re-inserting the new set, all in one transaction -- an immediate trigger
-- would see zero members mid-function and delete the room before the new
-- members are even inserted.
-- SECURITY DEFINER: the last member leaving is no longer a member (nor an
-- admin) by the time this runs, so RLS would silently skip the delete.
CREATE OR REPLACE FUNCTION chats.delete_room_if_empty()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    remaining int;
BEGIN
    SELECT count(*) INTO remaining FROM chats.room_members WHERE "roomId" = OLD."roomId";
    IF remaining = 0 THEN
        DELETE FROM chats.rooms WHERE id = OLD."roomId";
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

drop trigger if exists delete_room_if_empty_trigger on chats.room_members;
CREATE CONSTRAINT TRIGGER delete_room_if_empty_trigger
    AFTER DELETE ON chats.room_members
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION chats.delete_room_if_empty();

-- Delivers every message change to the room's private Realtime channel
-- (`chats:room:<roomId>`), where SupabaseChatController listens for it.
--
-- Broadcast from Database instead of Postgres Changes: chats.messages is
-- partitioned, and Postgres Changes reports each row under the partition it
-- physically lives in (chats.messages_p20261019, ...), so a subscription on
-- chats.messages never matches anything. Broadcast also scales better (one
-- message per change, authorized once at join time, instead of an RLS check
-- per change per subscriber) and DELETE events keep the whole old row, so
-- they can be routed to their room.
--
-- Who may join the channel is decided by the RLS policies on
-- realtime.messages (03_database_policy.sql). Requires Realtime with
-- Broadcast from Database support (Supabase cloud; self-hosted
-- supabase/realtime >= v2.33).
--
-- A failure to broadcast must never lose the message itself: it is reported
-- as a WARNING (visible in the Postgres logs) and the write goes through.
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

drop trigger if exists broadcast_message_change_trigger on chats.messages;
CREATE TRIGGER broadcast_message_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON chats.messages
    FOR EACH ROW EXECUTE FUNCTION chats.broadcast_message_change();
