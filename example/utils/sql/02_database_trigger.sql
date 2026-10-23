
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

-- Server-owned columns of a new message. For writes coming from the API
-- (anon/authenticated) only -- the SECURITY DEFINER RPCs and maintenance
-- run as the table owner and are not affected:
--   - status starts as 'sent' (read receipts go through mark_room_as_read);
--   - pin and reactions start empty (set_message_pinned and
--     toggle_message_reaction own them);
--   - "createdAt" is assigned by the database (its default), and a value
--     sent by the client is only accepted close to the server's clock. It is
--     the partition key and orders every member's timeline: a far-future
--     date would stay the room's last message for ever, sit in the default
--     partition and block pg_partman's maintenance. Rejected rather than
--     clamped: a BEFORE trigger can't move a row to another partition.
CREATE OR REPLACE FUNCTION chats.set_message_status_to_sent()
    RETURNS TRIGGER
    SET search_path = ''
AS $$
BEGIN
    NEW.status := 'sent';
    IF current_user IN ('anon', 'authenticated') THEN
        NEW.pinned := NULL;
        NEW.reactions := NULL;
        NEW."updatedAt" := NULL;
        IF NEW."createdAt" > now() + interval '2 minutes'
           OR NEW."createdAt" < now() - interval '10 minutes' THEN
            RAISE EXCEPTION 'message createdAt must be close to the server time (omit it to let the server set it)'
                USING ERRCODE = '22008';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

drop trigger if exists update_status_before_insert on chats.messages;
CREATE TRIGGER update_status_before_insert
    BEFORE INSERT ON chats.messages
    FOR EACH ROW EXECUTE FUNCTION chats.set_message_status_to_sent();

-- What an author may change on their own message (UPDATE is author-only
-- under RLS): its content. Identity and placement (id, room, author,
-- "createdAt"), the server-owned state (status, reactions, pin) and the
-- forward origin keep their stored values, and "updatedAt" is set by the
-- server whenever the content changes, so an edit is always visible.
-- API roles only, like chats.set_message_status_to_sent().
CREATE OR REPLACE FUNCTION chats.protect_message_columns()
    RETURNS TRIGGER
    SET search_path = ''
AS $$
BEGIN
    IF current_user NOT IN ('anon', 'authenticated') THEN
        RETURN NEW;
    END IF;
    NEW.id := OLD.id;
    NEW."roomId" := OLD."roomId";
    NEW."authorId" := OLD."authorId";
    NEW."createdAt" := OLD."createdAt";
    NEW.status := OLD.status;
    NEW.reactions := OLD.reactions;
    NEW.pinned := OLD.pinned;
    NEW.metadata := coalesce(NEW.metadata, '{}'::jsonb) - 'forwardedFrom'
        || CASE WHEN OLD.metadata ? 'forwardedFrom'
                THEN jsonb_build_object('forwardedFrom', OLD.metadata -> 'forwardedFrom')
                ELSE '{}'::jsonb END;
    IF NEW.metadata = '{}'::jsonb AND OLD.metadata IS NULL THEN
        NEW.metadata := NULL;
    END IF;
    IF (NEW.type, NEW.text, NEW.source, NEW.name, NEW."mimeType", NEW.size, NEW.duration,
        NEW.waveform, NEW.height, NEW.width, NEW."linkPreviewData", NEW."replyToMessageId", NEW.metadata)
       IS DISTINCT FROM
       (OLD.type, OLD.text, OLD.source, OLD.name, OLD."mimeType", OLD.size, OLD.duration,
        OLD.waveform, OLD.height, OLD.width, OLD."linkPreviewData", OLD."replyToMessageId", OLD.metadata) THEN
        NEW."updatedAt" := now();
    ELSE
        NEW."updatedAt" := OLD."updatedAt";
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

drop trigger if exists protect_message_columns_trigger on chats.messages;
CREATE TRIGGER protect_message_columns_trigger
    BEFORE UPDATE ON chats.messages
    FOR EACH ROW EXECUTE FUNCTION chats.protect_message_columns();

-- The origin of a forwarded message (metadata.forwardedFrom) is attested by
-- the database, never taken from the client: the client names the message
-- it forwards ({"sourceRoomId", "sourceMessageId"}), and this trigger
-- replaces that with the source's author, author name and date -- or keeps
-- the source's own attested origin when it is itself a forward. The source
-- is read with the caller's privileges (SECURITY INVOKER), so it must be a
-- message the forwarder can read. Any other forwardedFrom value is refused.
CREATE OR REPLACE FUNCTION chats.attest_forward_origin()
    RETURNS TRIGGER
    SET search_path = ''
AS $$
DECLARE
    v_claim jsonb;
    v_source record;
    v_name text;
BEGIN
    IF current_user NOT IN ('anon', 'authenticated')
       OR NOT coalesce(NEW.metadata ? 'forwardedFrom', false) THEN
        RETURN NEW;
    END IF;
    v_claim := NEW.metadata -> 'forwardedFrom';
    IF jsonb_typeof(v_claim) <> 'object'
       OR coalesce(v_claim ->> 'sourceRoomId', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR coalesce(v_claim ->> 'sourceMessageId', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RAISE EXCEPTION 'forwardedFrom must name the forwarded message (sourceRoomId, sourceMessageId)'
            USING ERRCODE = '22023';
    END IF;

    SELECT m."authorId", m."createdAt", m.metadata
    INTO v_source
    FROM chats.messages m
    WHERE m."roomId" = (v_claim ->> 'sourceRoomId')::uuid
      AND m.id = (v_claim ->> 'sourceMessageId')::uuid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'forwarded message not found' USING ERRCODE = 'P0002';
    END IF;

    IF jsonb_typeof(v_source.metadata -> 'forwardedFrom') = 'object'
       AND (v_source.metadata -> 'forwardedFrom' ->> 'attested')::boolean IS TRUE THEN
        NEW.metadata := jsonb_set(NEW.metadata, '{forwardedFrom}', v_source.metadata -> 'forwardedFrom');
    ELSE
        SELECT nullif(trim(concat_ws(' ', u."firstName", u."lastName")), '')
        INTO v_name
        FROM chats.users u WHERE u.id = v_source."authorId";
        NEW.metadata := jsonb_set(NEW.metadata, '{forwardedFrom}', jsonb_strip_nulls(jsonb_build_object(
            'authorId', v_source."authorId",
            'authorName', v_name,
            'createdAt', v_source."createdAt",
            'attested', true
        )));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

drop trigger if exists attest_forward_origin_trigger on chats.messages;
CREATE TRIGGER attest_forward_origin_trigger
    BEFORE INSERT ON chats.messages
    FOR EACH ROW EXECUTE FUNCTION chats.attest_forward_origin();

-- Registers every message id in chats.message_ids (01_database_schema.sql),
-- making ids unique across the partitioned table: reusing another message's
-- id fails with a unique violation (23505) instead of creating a second row
-- that RPCs, deletes and clients addressing messages by id would confuse
-- with the first. Releases the id when the message is deleted.
CREATE OR REPLACE FUNCTION chats.claim_message_id()
    RETURNS TRIGGER
    SECURITY DEFINER
    SET search_path = ''
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        DELETE FROM chats.message_ids WHERE id = OLD.id;
        RETURN OLD;
    END IF;
    -- API roles can't change an id (chats.protect_message_columns() keeps
    -- the stored one, and runs after this trigger): nothing to re-register.
    IF TG_OP = 'UPDATE' AND (NEW.id = OLD.id OR current_user IN ('anon', 'authenticated')) THEN
        RETURN NEW;
    END IF;
    INSERT INTO chats.message_ids (id) VALUES (NEW.id);
    IF TG_OP = 'UPDATE' THEN
        DELETE FROM chats.message_ids WHERE id = OLD.id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

drop trigger if exists claim_message_id_trigger on chats.messages;
CREATE TRIGGER claim_message_id_trigger
    BEFORE INSERT OR UPDATE OF id ON chats.messages
    FOR EACH ROW EXECUTE FUNCTION chats.claim_message_id();

drop trigger if exists release_message_id_trigger on chats.messages;
CREATE TRIGGER release_message_id_trigger
    AFTER DELETE ON chats.messages
    FOR EACH ROW EXECUTE FUNCTION chats.claim_message_id();

-- A message's storage media (its `source`, when it points at the
-- chats_assets bucket) can't be deleted by SQL alone -- the storage backend
-- needs a real API call. Instead, record the bucket/path here for the
-- cleanup-media Edge Function (see supabase/functions/cleanup-media) to
-- pick up and remove later, whenever a message referencing one is deleted.
-- Deleting the message row itself still happens immediately, same as today.
--
-- `source` is written by the message's author, so it is only trusted for
-- what the message may own: an object of the chats_assets bucket inside the
-- message's own room folder (`<roomId>/...`, or the room's legacy v1 bigint
-- folder), not referenced by any other message. Anything else (another
-- room, another bucket, an external URL) is left alone -- the cleanup
-- function deletes with the service role, which bypasses storage RLS.
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
    v_bucket text;
    v_path text;
    v_folder text;
    v_legacy uuid;
BEGIN
    IF OLD.source IS NULL THEN
        RETURN OLD;
    END IF;
    idx := position(marker IN OLD.source);
    IF idx = 0 THEN
        RETURN OLD;
    END IF;
    rest := split_part(split_part(substring(OLD.source FROM idx + char_length(marker)), '?', 1), '#', 1);
    slash_idx := position('/' IN rest);
    IF slash_idx = 0 THEN
        RETURN OLD;
    END IF;
    v_bucket := substring(rest FROM 1 FOR slash_idx - 1);
    v_path := substring(rest FROM slash_idx + 1);
    IF v_bucket <> 'chats_assets'
       OR v_path !~ '^[^/]+/[^/]+$'
       OR v_path ~ '(^|/)\.\.?(/|$)' THEN
        RETURN OLD;
    END IF;

    v_folder := split_part(v_path, '/', 1);
    IF v_folder <> OLD."roomId"::text THEN
        IF v_folder ~ '^[0-9]{1,18}$' AND to_regclass('chats.room_id_migration_map') IS NOT NULL THEN
            EXECUTE 'SELECT new_id FROM chats.room_id_migration_map WHERE old_id = $1'
                INTO v_legacy USING v_folder::bigint;
        END IF;
        IF v_legacy IS DISTINCT FROM OLD."roomId" THEN
            RETURN OLD;
        END IF;
    END IF;

    IF EXISTS (SELECT 1 FROM chats.messages m WHERE m.source = OLD.source) THEN
        RETURN OLD;
    END IF;

    INSERT INTO chats.media_pending_deletion ("bucketId", path) VALUES (v_bucket, v_path);
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
-- realtime.messages (03_database_policy.sql). Clients can't send on it: only
-- the database does, so every event on it is authoritative (the typing
-- indicator has its own `chats:room:<roomId>:typing` channel). Requires
-- Realtime with Broadcast from Database support (Supabase cloud; self-hosted
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

-- ----------------------------------------------------------------------------
-- Room and membership changes, per user
--
-- Every member of a room is told, on their own private channel
-- (`chats:user:<userId>`, joinable by that user only), that the room changed
-- (`room_change` event, payload {"roomId", "removed"}): the room was
-- updated, someone joined or left it, a role changed. "removed" is true for
-- the user who was removed (or left, or whose room was deleted). Clients
-- refetch the room through RLS. Replaces Postgres Changes on chats.rooms and
-- chats.room_members, whose DELETE events Realtime delivers to every
-- subscriber without RLS.
--
-- Statement-level triggers with transition tables: creating a room with N
-- members sends N events, not one per member per inserted row. Failures are
-- reported as WARNINGs, like chats.broadcast_message_change().
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chats.send_room_change(p_room_id uuid, p_user_id uuid, p_removed boolean)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS $$
BEGIN
    PERFORM realtime.send(
        jsonb_build_object('roomId', p_room_id, 'removed', p_removed),
        'room_change',
        'chats:user:' || p_user_id::text,
        true
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'chats.send_room_change: % (room %, user %)', SQLERRM, p_room_id, p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION chats.broadcast_members_upserted()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT m."roomId", m."userId"
        FROM chats.room_members m
        WHERE m."roomId" IN (SELECT "roomId" FROM changed_rows)
    LOOP
        PERFORM chats.send_room_change(r."roomId", r."userId", false);
    END LOOP;
    RETURN NULL;
END;
$$;

-- A role change concerns every member (room info, admin actions); the
-- per-member columns ("lastReadAt", "pinnedAt", "mutedUntil") only the
-- member themselves -- marking a room as read must not make every other
-- member refetch it.
CREATE OR REPLACE FUNCTION chats.broadcast_members_updated()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT m."roomId", m."userId"
        FROM chats.room_members m
        WHERE m."roomId" IN (
            SELECT n."roomId" FROM changed_rows n
            JOIN previous_rows o ON o."roomId" = n."roomId" AND o."userId" = n."userId"
            WHERE o.role IS DISTINCT FROM n.role
        )
        UNION
        SELECT n."roomId", n."userId" FROM changed_rows n
    LOOP
        PERFORM chats.send_room_change(r."roomId", r."userId", false);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION chats.broadcast_members_deleted()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT o."roomId", o."userId", true AS removed
        FROM removed_rows o
        UNION
        SELECT DISTINCT m."roomId", m."userId", false
        FROM chats.room_members m
        WHERE m."roomId" IN (SELECT "roomId" FROM removed_rows)
    LOOP
        PERFORM chats.send_room_change(r."roomId", r."userId", r.removed);
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION chats.broadcast_rooms_updated()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT DISTINCT m."roomId", m."userId"
        FROM chats.room_members m
        WHERE m."roomId" IN (SELECT id FROM changed_rows)
    LOOP
        PERFORM chats.send_room_change(r."roomId", r."userId", false);
    END LOOP;
    RETURN NULL;
END;
$$;

drop trigger if exists broadcast_members_inserted_trigger on chats.room_members;
CREATE TRIGGER broadcast_members_inserted_trigger
    AFTER INSERT ON chats.room_members
    REFERENCING NEW TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION chats.broadcast_members_upserted();

drop trigger if exists broadcast_members_updated_trigger on chats.room_members;
CREATE TRIGGER broadcast_members_updated_trigger
    AFTER UPDATE ON chats.room_members
    REFERENCING OLD TABLE AS previous_rows NEW TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION chats.broadcast_members_updated();

drop trigger if exists broadcast_members_deleted_trigger on chats.room_members;
CREATE TRIGGER broadcast_members_deleted_trigger
    AFTER DELETE ON chats.room_members
    REFERENCING OLD TABLE AS removed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION chats.broadcast_members_deleted();

drop trigger if exists broadcast_rooms_updated_trigger on chats.rooms;
CREATE TRIGGER broadcast_rooms_updated_trigger
    AFTER UPDATE ON chats.rooms
    REFERENCING NEW TABLE AS changed_rows
    FOR EACH STATEMENT EXECUTE FUNCTION chats.broadcast_rooms_updated();
