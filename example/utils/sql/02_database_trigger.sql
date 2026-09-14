
CREATE OR REPLACE FUNCTION chats.handle_new_user()
    RETURNS trigger
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY DEFINER
    SET search_path=public
    SET search_path = ''
AS $BODY$
BEGIN
    insert into chats.users (id, "createdAt", "updatedAt", "lastSeen")
    values (new.id, now(), now(), now());
    return new;
end;
$BODY$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
    after insert on auth.users
    for each row execute procedure chats.handle_new_user();


CREATE OR REPLACE FUNCTION chats.update_last_messages()
    RETURNS TRIGGER
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
        SET "updatedAt" = now(),
            "lastMessages" = jsonb_build_array(latest_message)
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
CREATE OR REPLACE FUNCTION chats.queue_media_for_deletion()
    RETURNS TRIGGER
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
CREATE OR REPLACE FUNCTION chats.delete_room_if_empty()
    RETURNS TRIGGER
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
