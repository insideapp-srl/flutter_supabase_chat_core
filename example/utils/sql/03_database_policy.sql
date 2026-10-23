-- ============================================================================
-- chats: access helpers, RPCs and row level security policies (v2)
--
-- Idempotent: every function is CREATE OR REPLACE'd and every policy is
-- dropped and recreated, so re-running this file is always safe.
--
-- Access model:
--   - chats.users: readable by any authenticated user, updatable by its
--     owner only, created/deleted by triggers/foreign keys only.
--   - chats.rooms: readable by members. Created only through
--     chats.create_room() (atomic: room + members in one transaction, and
--     direct rooms are de-duplicated). Group rooms are renamed/deleted by
--     their admins, direct rooms by either member.
--   - chats.room_members: readable by members of the same room. Group admins
--     add/remove members and change roles; anyone can leave a room.
--   - chats.messages: readable/writable by room members; a message can only
--     be sent as yourself, edited by its author, and deleted by its author
--     (or a group admin). Read receipts and reactions go through
--     SECURITY DEFINER RPCs, since they touch other people's rows.
-- ============================================================================

DROP POLICY IF EXISTS "chats.users_grant_create" ON chats.users;
DROP POLICY IF EXISTS "chats.users_grant_read" ON chats.users;
DROP POLICY IF EXISTS "chats.users_grant_update" ON chats.users;
DROP POLICY IF EXISTS "chats.users_grant_delete" ON chats.users;

DROP POLICY IF EXISTS "chats.rooms_grant_create" ON chats.rooms;
DROP POLICY IF EXISTS "chats.rooms_grant_read" ON chats.rooms;
DROP POLICY IF EXISTS "chats.rooms_grant_update" ON chats.rooms;
DROP POLICY IF EXISTS "chats.rooms_grant_delete" ON chats.rooms;

DROP POLICY IF EXISTS "chats.room_members_grant_create" ON chats.room_members;
DROP POLICY IF EXISTS "chats.room_members_grant_read" ON chats.room_members;
DROP POLICY IF EXISTS "chats.room_members_grant_update" ON chats.room_members;
DROP POLICY IF EXISTS "chats.room_members_grant_delete" ON chats.room_members;

DROP POLICY IF EXISTS "chats.messages_grant_create" ON chats.messages;
DROP POLICY IF EXISTS "chats.messages_grant_read" ON chats.messages;
DROP POLICY IF EXISTS "chats.messages_grant_update" ON chats.messages;
DROP POLICY IF EXISTS "chats.messages_grant_delete" ON chats.messages;

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION chats.is_auth()
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY INVOKER
    SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION chats.is_owner(user_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY INVOKER
    SET search_path = ''
AS $$
    SELECT auth.uid() = user_id;
$$;

-- Superseded by chats.room_members (chats.rooms."userIds" no longer
-- exists) -- all policies calling it were already dropped above.
DROP FUNCTION IF EXISTS chats.is_member(uuid[]);

-- chats.rooms/messages ids are uuid since 2.x — drop the old bigint-arg
-- overload too. The v1 chats_assets storage policies still call it: drop
-- them first, 04_storage.sql recreates them on top of the uuid helpers.
DROP POLICY IF EXISTS "storage.object_grant_create_auth_chats_assets" ON storage.objects;
DROP POLICY IF EXISTS "storage.object_grant_read_auth_chats_assets" ON storage.objects;
DROP POLICY IF EXISTS "storage.object_grant_update_auth_chats_assets" ON storage.objects;
DROP POLICY IF EXISTS "storage.object_grant_delete_auth_chats_assets" ON storage.objects;
DROP FUNCTION IF EXISTS chats.is_chat_member(bigint);

-- Superseded by chats.create_room() and per-row membership management.
DROP FUNCTION IF EXISTS chats.replace_room_members(uuid, jsonb);

-- SECURITY DEFINER on purpose: it is called from chats.room_members' own
-- SELECT policy. As SECURITY INVOKER its lookup on chats.room_members would
-- re-apply that same policy, recursing forever.
CREATE OR REPLACE FUNCTION chats.is_chat_member(room_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1 FROM chats.room_members
        WHERE "roomId" = room_id AND "userId" = auth.uid()
    );
$$;

-- True when the caller is an admin of the room (group rooms), or a member
-- of a direct room (both members of a 1-to-1 conversation have the same
-- rights over it).
CREATE OR REPLACE FUNCTION chats.is_chat_admin(room_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM chats.room_members rm
        JOIN chats.rooms r ON r.id = rm."roomId"
        WHERE rm."roomId" = room_id
          AND rm."userId" = auth.uid()
          AND (rm.role = 'admin' OR r.type = 'direct')
    );
$$;

-- The caller's role in a room ('admin', 'moderator', or NULL for a plain
-- member or a non-member).
CREATE OR REPLACE FUNCTION chats.chat_member_role(room_id uuid)
    RETURNS text
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = ''
AS $$
    SELECT role FROM chats.room_members
    WHERE "roomId" = room_id AND "userId" = auth.uid();
$$;

-- Storage helper: the room a `chats_assets` object path (`<roomId>/<file>`)
-- belongs to, from its first folder; NULL when it isn't a room folder.
-- Never raises for a folder that isn't a uuid -- a bare `::uuid` cast inside
-- a storage policy could otherwise fail queries on unrelated objects, since
-- SQL doesn't guarantee the evaluation order of the policy's AND-ed
-- conditions.
CREATE OR REPLACE FUNCTION chats.room_id_from_path(object_name text)
    RETURNS uuid
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    folder text := split_part(object_name, '/', 1);
    mapped uuid;
BEGIN
    IF folder ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RETURN folder::uuid;
    END IF;
    -- Attachments uploaded before the v1 -> v2 migration live under the old
    -- bigint room id (`<old id>/<file>`): resolve it through the migration
    -- map, so they stay readable without moving any storage object.
    IF folder ~ '^[0-9]{1,18}$' AND to_regclass('chats.room_id_migration_map') IS NOT NULL THEN
        EXECUTE 'SELECT new_id FROM chats.room_id_migration_map WHERE old_id = $1'
            INTO mapped USING folder::bigint;
        RETURN mapped;
    END IF;
    RETURN NULL;
END;
$$;

-- Storage helper: is the caller a member of the room of a `chats_assets`
-- object path?
CREATE OR REPLACE FUNCTION chats.is_chat_member_path(object_name text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = ''
AS $$
    SELECT coalesce(chats.is_chat_member(chats.room_id_from_path(object_name)), false);
$$;

-- Storage helper: is the caller an admin of the (group) room of a
-- `chats_assets` object path? Mirrors who may delete someone else's message.
CREATE OR REPLACE FUNCTION chats.is_chat_admin_path(object_name text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path = ''
AS $$
    SELECT coalesce(chats.chat_member_role(chats.room_id_from_path(object_name)) = 'admin', false);
$$;

-- Realtime helper: the room a room channel topic belongs to --
-- `chats:room:<roomId>` (message changes, sent by the database only) or
-- `chats:room:<roomId>:typing` (typing indicator, sent by members) -- or
-- NULL for any other topic or a malformed id (same safe-cast rationale as
-- above).
CREATE OR REPLACE FUNCTION chats.room_id_from_topic(topic text, typing boolean)
    RETURNS uuid
    LANGUAGE plpgsql
    IMMUTABLE
    SECURITY INVOKER
    SET search_path = ''
AS $$
DECLARE
    room text;
BEGIN
    IF topic IS NULL OR left(topic, 11) <> 'chats:room:' THEN
        RETURN NULL;
    END IF;
    room := substr(topic, 12);
    IF typing THEN
        IF right(room, 7) <> ':typing' THEN
            RETURN NULL;
        END IF;
        room := left(room, -7);
    END IF;
    IF room !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RETURN NULL;
    END IF;
    RETURN room::uuid;
END;
$$;

-- Realtime helper: may the caller receive on a room channel topic (message
-- changes or typing indicator)? Members of the room only.
CREATE OR REPLACE FUNCTION chats.is_chat_member_topic(topic text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY INVOKER
    SET search_path = ''
AS $$
    SELECT coalesce(chats.is_chat_member(
        coalesce(chats.room_id_from_topic(topic, false), chats.room_id_from_topic(topic, true))
    ), false);
$$;

-- Realtime helper: may the caller send on a topic? Only on the typing
-- channel of a room they are a member of: the message channel carries
-- database events only, so a member can't forge them.
CREATE OR REPLACE FUNCTION chats.is_chat_typing_topic(topic text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY INVOKER
    SET search_path = ''
AS $$
    SELECT coalesce(chats.is_chat_member(chats.room_id_from_topic(topic, true)), false);
$$;

-- Realtime helper: is the topic the caller's own user channel
-- (`chats:user:<uid>`, room and membership changes)?
CREATE OR REPLACE FUNCTION chats.is_own_user_topic(topic text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY INVOKER
    SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL AND topic = 'chats:user:' || auth.uid()::text;
$$;

-- Realtime helpers: online status channels (`online-user-<uid>`, see
-- SupabaseChatCoreConfig.realtimeOnlineUserPrefixChannel). Any signed-in
-- user may watch any user's status (like profiles, readable by everyone),
-- only the user themselves may publish it.
CREATE OR REPLACE FUNCTION chats.is_presence_topic(topic text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY INVOKER
    SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL
       AND coalesce(topic ~* '^online-user-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', false);
$$;

CREATE OR REPLACE FUNCTION chats.is_own_presence_topic(topic text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY INVOKER
    SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL AND topic = 'online-user-' || auth.uid()::text;
$$;

-- Storage helper: is the first folder of an object path (`<uid>/<file>`)
-- the caller's own user id? Same safe-cast rationale as above.
CREATE OR REPLACE FUNCTION chats.is_owner_path(object_name text)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY INVOKER
    SET search_path = ''
AS $$
    SELECT auth.uid() IS NOT NULL
       AND split_part(object_name, '/', 1) = auth.uid()::text;
$$;

-- ----------------------------------------------------------------------------
-- RPCs
-- ----------------------------------------------------------------------------

-- Creates a room together with its members, atomically, and returns its id.
--
--   p_type          'direct' or 'group'.
--   p_user_ids      the other members (the caller is always added).
--   p_name          group name (ignored for direct rooms).
--   p_image_url     group avatar (ignored for direct rooms).
--   p_metadata      custom data stored on the room.
--   p_creator_role  the caller's role in a group room (default 'admin').
--
-- A direct room is unique per pair of users *and* metadata scope: if one
-- already exists whose metadata contains every key/value of p_metadata, its
-- id is returned instead of creating a duplicate. That way apps that
-- partition chats (e.g. by workspace, through metadata) get one direct room
-- per pair per partition.
--
-- SECURITY DEFINER because the caller can't satisfy the rooms/room_members
-- RLS policies for a room that has no members yet.
CREATE OR REPLACE FUNCTION chats.create_room(
    p_type text,
    p_user_ids uuid[],
    p_name text DEFAULT NULL,
    p_image_url text DEFAULT NULL,
    p_metadata jsonb DEFAULT NULL,
    p_creator_role text DEFAULT 'admin'
)
    RETURNS uuid
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_members uuid[];
    v_room_id uuid;
    v_now timestamptz := now();
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'create_room requires an authenticated user'
            USING ERRCODE = '42501';
    END IF;
    IF p_type IS NULL OR p_type NOT IN ('direct', 'group') THEN
        RAISE EXCEPTION 'invalid room type: %', p_type USING ERRCODE = '22023';
    END IF;

    SELECT array_agg(DISTINCT u ORDER BY u)
    INTO v_members
    FROM unnest(coalesce(p_user_ids, '{}'::uuid[]) || v_uid) AS u
    WHERE u IS NOT NULL;

    IF EXISTS (
        SELECT 1 FROM unnest(v_members) AS u
        WHERE NOT EXISTS (SELECT 1 FROM chats.users cu WHERE cu.id = u)
    ) THEN
        RAISE EXCEPTION 'unknown user id in p_user_ids' USING ERRCODE = '23503';
    END IF;

    IF p_type = 'direct' THEN
        IF cardinality(v_members) <> 2 THEN
            RAISE EXCEPTION 'a direct room needs exactly one other user'
                USING ERRCODE = '22023';
        END IF;

        -- Serialize concurrent creations for the same pair, so two clients
        -- opening the same conversation at once can't create two rooms.
        PERFORM pg_advisory_xact_lock(
            hashtextextended('chats.direct:' || v_members[1] || ':' || v_members[2], 0)
        );

        SELECT r.id INTO v_room_id
        FROM chats.rooms r
        WHERE r.type = 'direct'
          AND coalesce(r.metadata, '{}'::jsonb) @> coalesce(p_metadata, '{}'::jsonb)
          AND (SELECT array_agg(rm."userId" ORDER BY rm."userId")
               FROM chats.room_members rm WHERE rm."roomId" = r.id) = v_members
        ORDER BY r."createdAt"
        LIMIT 1;

        IF v_room_id IS NOT NULL THEN
            RETURN v_room_id;
        END IF;

        INSERT INTO chats.rooms (type, metadata, "createdAt", "updatedAt")
        VALUES ('direct', p_metadata, v_now, v_now)
        RETURNING id INTO v_room_id;

        INSERT INTO chats.room_members ("roomId", "userId", role, "lastReadAt")
        SELECT v_room_id, u, NULL, CASE WHEN u = v_uid THEN v_now END
        FROM unnest(v_members) AS u;
    ELSE
        INSERT INTO chats.rooms (type, name, "imageUrl", metadata, "createdAt", "updatedAt")
        VALUES ('group', p_name, p_image_url, p_metadata, v_now, v_now)
        RETURNING id INTO v_room_id;

        INSERT INTO chats.room_members ("roomId", "userId", role, "lastReadAt")
        SELECT v_room_id, u,
               CASE WHEN u = v_uid THEN p_creator_role END,
               CASE WHEN u = v_uid THEN v_now END
        FROM unnest(v_members) AS u;
    END IF;

    RETURN v_room_id;
END;
$$;

-- Marks every message of a room as read by the caller: stores the read
-- time on the caller's membership (drives rooms_l."unreadCount") and flips
-- other members' messages to status 'seen' (drives the sender's read
-- receipts, delivered to them as Realtime UPDATE events). In a group room a
-- message is 'seen' as soon as any other member read it.
CREATE OR REPLACE FUNCTION chats.mark_room_as_read(p_room_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_now timestamptz := now();
BEGIN
    IF NOT chats.is_chat_member(p_room_id) THEN
        RAISE EXCEPTION 'not a member of this room' USING ERRCODE = '42501';
    END IF;

    UPDATE chats.room_members
    SET "lastReadAt" = v_now
    WHERE "roomId" = p_room_id AND "userId" = v_uid;

    UPDATE chats.messages
    SET status = 'seen'
    WHERE "roomId" = p_room_id
      AND "authorId" <> v_uid
      AND "createdAt" <= v_now
      AND status IS DISTINCT FROM 'seen';
END;
$$;

-- Adds or removes the caller's [p_reaction] (e.g. an emoji) on a message,
-- atomically (reactions is a jsonb map shared by every member -- a
-- read-modify-write from the client would lose concurrent reactions).
-- Returns the message's updated reactions map.
CREATE OR REPLACE FUNCTION chats.toggle_message_reaction(p_message_id uuid, p_reaction text)
    RETURNS jsonb
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    v_uid text := auth.uid()::text;
    v_room_id uuid;
    v_created_at timestamptz;
    v_reactions jsonb;
    v_users jsonb;
BEGIN
    IF p_reaction IS NULL OR length(p_reaction) = 0 OR length(p_reaction) > 64 THEN
        RAISE EXCEPTION 'invalid reaction' USING ERRCODE = '22023';
    END IF;

    -- Authorize and update the very same row: (id, "createdAt") is the
    -- primary key. Ids are unique (chats.message_ids); STRICT makes sure an
    -- ambiguous id can never select one row and update another.
    BEGIN
        SELECT "roomId", "createdAt", coalesce(reactions, '{}'::jsonb)
        INTO STRICT v_room_id, v_created_at, v_reactions
        FROM chats.messages
        WHERE id = p_message_id
        FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND OR TOO_MANY_ROWS THEN
        RAISE EXCEPTION 'message not found' USING ERRCODE = 'P0002';
    END;

    IF NOT chats.is_chat_member(v_room_id) THEN
        RAISE EXCEPTION 'message not found' USING ERRCODE = 'P0002';
    END IF;

    v_users := coalesce(v_reactions -> p_reaction, '[]'::jsonb);
    IF v_users ? v_uid THEN
        v_users := v_users - v_uid;
    ELSE
        v_users := v_users || to_jsonb(v_uid);
    END IF;

    IF jsonb_array_length(v_users) = 0 THEN
        v_reactions := v_reactions - p_reaction;
    ELSE
        v_reactions := jsonb_set(v_reactions, ARRAY[p_reaction], v_users);
    END IF;

    UPDATE chats.messages
    SET reactions = CASE WHEN v_reactions = '{}'::jsonb THEN NULL ELSE v_reactions END
    WHERE id = p_message_id AND "createdAt" = v_created_at AND "roomId" = v_room_id;

    RETURN v_reactions;
END;
$$;

-- Pins (p_pinned = true) or unpins a room on top of the caller's own rooms
-- list. Per-member: other members don't see it.
CREATE OR REPLACE FUNCTION chats.pin_room(p_room_id uuid, p_pinned boolean)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
AS $$
BEGIN
    UPDATE chats.room_members
    SET "pinnedAt" = CASE WHEN p_pinned THEN now() END
    WHERE "roomId" = p_room_id AND "userId" = auth.uid();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'not a member of this room' USING ERRCODE = '42501';
    END IF;
END;
$$;

-- Mutes a room for the caller until p_until ('infinity' for ever), or
-- unmutes it (NULL). Per-member: apps read rooms_l."mutedUntil" to skip
-- notifications/badges.
CREATE OR REPLACE FUNCTION chats.mute_room(p_room_id uuid, p_until timestamptz)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
AS $$
BEGIN
    UPDATE chats.room_members
    SET "mutedUntil" = p_until
    WHERE "roomId" = p_room_id AND "userId" = auth.uid();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'not a member of this room' USING ERRCODE = '42501';
    END IF;
END;
$$;

-- Pins/unpins a message for everyone in its room: either member of a
-- direct room, or an admin of a group room. SECURITY DEFINER since the
-- message usually belongs to someone else (UPDATE is author-only under RLS).
CREATE OR REPLACE FUNCTION chats.set_message_pinned(p_message_id uuid, p_pinned boolean)
    RETURNS void
    LANGUAGE plpgsql
    VOLATILE
    SECURITY DEFINER
    SET search_path = ''
AS $$
DECLARE
    v_room_id uuid;
    v_created_at timestamptz;
BEGIN
    -- Same row binding as chats.toggle_message_reaction().
    BEGIN
        SELECT "roomId", "createdAt" INTO STRICT v_room_id, v_created_at
        FROM chats.messages WHERE id = p_message_id;
    EXCEPTION WHEN NO_DATA_FOUND OR TOO_MANY_ROWS THEN
        RAISE EXCEPTION 'message not found' USING ERRCODE = 'P0002';
    END;
    IF NOT chats.is_chat_member(v_room_id) THEN
        RAISE EXCEPTION 'message not found' USING ERRCODE = 'P0002';
    END IF;
    IF NOT chats.is_chat_admin(v_room_id) THEN
        RAISE EXCEPTION 'only room admins can pin messages' USING ERRCODE = '42501';
    END IF;
    UPDATE chats.messages
    SET pinned = CASE WHEN p_pinned THEN true END
    WHERE id = p_message_id AND "createdAt" = v_created_at AND "roomId" = v_room_id;
END;
$$;

REVOKE ALL ON FUNCTION chats.create_room(text, uuid[], text, text, jsonb, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.mark_room_as_read(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.toggle_message_reaction(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION chats.create_room(text, uuid[], text, text, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION chats.mark_room_as_read(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION chats.toggle_message_reaction(uuid, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION chats.pin_room(uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.mute_room(uuid, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.set_message_pinned(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION chats.pin_room(uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION chats.mute_room(uuid, timestamptz) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION chats.set_message_pinned(uuid, boolean) TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- chats.users
--
-- UPDATE policies state their rule once, in USING: without WITH CHECK,
-- Postgres applies the USING expression to the new row too, so the row can
-- neither be selected nor moved outside of the rule.
-- ----------------------------------------------------------------------------

CREATE POLICY "chats.users_grant_create"
    ON chats.users
    AS PERMISSIVE
    FOR INSERT
    TO authenticated
    WITH CHECK (false); -- Created by trigger

CREATE POLICY "chats.users_grant_read"
    ON chats.users
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING (chats.is_auth());

CREATE POLICY "chats.users_grant_update"
    ON chats.users
    AS PERMISSIVE
    FOR UPDATE
    TO authenticated
    USING (chats.is_owner(id));

CREATE POLICY "chats.users_grant_delete"
    ON chats.users
    AS PERMISSIVE
    FOR DELETE
    TO authenticated
    USING (false); -- Delete by foreign key

-- ----------------------------------------------------------------------------
-- chats.rooms
-- ----------------------------------------------------------------------------

CREATE POLICY "chats.rooms_grant_create"
    ON chats.rooms
    AS PERMISSIVE
    FOR INSERT
    TO authenticated
    WITH CHECK (false); -- Created by chats.create_room()

CREATE POLICY "chats.rooms_grant_read"
    ON chats.rooms
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING (chats.is_chat_member(id));

CREATE POLICY "chats.rooms_grant_update"
    ON chats.rooms
    AS PERMISSIVE
    FOR UPDATE
    TO authenticated
    USING (chats.is_chat_admin(id));

CREATE POLICY "chats.rooms_grant_delete"
    ON chats.rooms
    AS PERMISSIVE
    FOR DELETE
    TO authenticated
    USING (chats.is_chat_admin(id));

-- ----------------------------------------------------------------------------
-- chats.room_members
-- ----------------------------------------------------------------------------

-- Only group admins add members, and only to group rooms (a direct room's
-- membership is fixed at creation). There is deliberately no "add yourself"
-- path: knowing a room's id must not be enough to join it.
CREATE POLICY "chats.room_members_grant_create"
    ON chats.room_members
    AS PERMISSIVE
    FOR INSERT
    TO authenticated
    WITH CHECK (
        chats.is_chat_admin("roomId")
        AND EXISTS (SELECT 1 FROM chats.rooms r WHERE r.id = "roomId" AND r.type = 'group')
    );

CREATE POLICY "chats.room_members_grant_read"
    ON chats.room_members
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING (chats.is_chat_member("roomId"));

-- Role changes, by the admins of a group room. Only the role column is
-- writable at all (column privileges in 99_database_schema_permission.sql):
-- moving a membership to another room or user would bypass the INSERT rules
-- above (e.g. adding a third member to a direct room). "lastReadAt",
-- "pinnedAt" and "mutedUntil" go through chats.mark_room_as_read(),
-- chats.pin_room() and chats.mute_room().
CREATE POLICY "chats.room_members_grant_update"
    ON chats.room_members
    AS PERMISSIVE
    FOR UPDATE
    TO authenticated
    USING (
        chats.chat_member_role("roomId") = 'admin'
        AND EXISTS (SELECT 1 FROM chats.rooms r WHERE r.id = "roomId" AND r.type = 'group')
    );

-- Covers both "leave a room" (deleting your own row) and "remove a member"
-- (a group admin deleting someone else's row). A room left without members
-- is deleted by the delete_room_if_empty trigger.
CREATE POLICY "chats.room_members_grant_delete"
    ON chats.room_members
    AS PERMISSIVE
    FOR DELETE
    TO authenticated
    USING ("userId" = (SELECT auth.uid()) OR chats.is_chat_admin("roomId"));

-- ----------------------------------------------------------------------------
-- chats.messages
-- ----------------------------------------------------------------------------

CREATE POLICY "chats.messages_grant_create"
    ON chats.messages
    AS PERMISSIVE
    FOR INSERT
    TO authenticated
    WITH CHECK (chats.is_chat_member("roomId") AND "authorId" = (SELECT auth.uid()));

CREATE POLICY "chats.messages_grant_read"
    ON chats.messages
    AS PERMISSIVE
    FOR SELECT
    TO authenticated
    USING (chats.is_chat_member("roomId"));

CREATE POLICY "chats.messages_grant_update"
    ON chats.messages
    AS PERMISSIVE
    FOR UPDATE
    TO authenticated
    USING (chats.is_chat_member("roomId") AND "authorId" = (SELECT auth.uid()));

CREATE POLICY "chats.messages_grant_delete"
    ON chats.messages
    AS PERMISSIVE
    FOR DELETE
    TO authenticated
    USING (
        chats.is_chat_member("roomId")
        AND ("authorId" = (SELECT auth.uid()) OR chats.chat_member_role("roomId") = 'admin')
    );

-- ----------------------------------------------------------------------------
-- Realtime: private channels
--
-- Realtime authorizes joining a private channel (receiving its broadcasts
-- and presence) against SELECT policies on realtime.messages, and sending
-- to it (broadcast, presence tracking) against INSERT policies:
--
--   chats:room:<roomId>         message changes, sent by the database only
--                               (chats.broadcast_message_change): members
--                               receive, nobody sends.
--   chats:room:<roomId>:typing  typing indicator: members receive and send.
--   chats:user:<uid>            room/membership changes of that user
--                               (chats.send_room_change): the user only.
--   online-user-<uid>           online status (Presence): any signed-in
--                               user watches, only <uid> publishes.
--
-- Only these topic shapes are matched, so policies other apps define on
-- realtime.messages are unaffected.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "chats.realtime_room_read" ON realtime.messages;
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

DROP POLICY IF EXISTS "chats.realtime_room_write" ON realtime.messages;
CREATE POLICY "chats.realtime_room_write"
    ON realtime.messages
    AS PERMISSIVE
    FOR INSERT
    TO authenticated
    WITH CHECK (
        (extension = 'broadcast' AND chats.is_chat_typing_topic((SELECT realtime.topic())))
        OR (extension = 'presence' AND chats.is_own_presence_topic((SELECT realtime.topic())))
    );
