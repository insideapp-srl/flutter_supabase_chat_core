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
DROP POLICY IF EXISTS "chats.room_members_grant_delete" ON chats.room_members;

DROP POLICY IF EXISTS "chats.messages_grant_create" ON chats.messages;
DROP POLICY IF EXISTS "chats.messages_grant_read" ON chats.messages;
DROP POLICY IF EXISTS "chats.messages_grant_update" ON chats.messages;
DROP POLICY IF EXISTS "chats.messages_grant_delete" ON chats.messages;

CREATE OR REPLACE FUNCTION chats.is_auth()
    RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY INVOKER
    SET search_path = ''
AS $BODY$
BEGIN
  return auth.uid() IS NOT NULL;
end;
$BODY$;

CREATE OR REPLACE FUNCTION chats.is_owner(user_id uuid)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY INVOKER
    SET search_path = ''
AS $BODY$
BEGIN
  return auth.uid() = user_id;
end;
$BODY$;

-- Superseded by chats.room_members (chats.rooms."userIds" no longer
-- exists) -- all policies calling it were already dropped above, so
-- nothing depends on it at this point.
DROP FUNCTION IF EXISTS chats.is_member(uuid[]);

-- chats.rooms/messages ids are uuid since 2.x — drop the old bigint-arg
-- overload too, for the same reason.
DROP FUNCTION IF EXISTS chats.is_chat_member(bigint);

CREATE OR REPLACE FUNCTION chats.is_chat_member(room_id uuid)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY INVOKER
    SET search_path = ''
AS $BODY$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM chats.room_members
        WHERE "roomId" = room_id AND "userId" = auth.uid()
    );
end;
$BODY$;

-- Replaces a room's entire membership list atomically (delete all, then
-- insert the new set) in a single transaction, so the DEFERRED
-- delete_room_if_empty trigger (02_database_trigger.sql) never sees a
-- (temporarily) empty room and deletes it out from under the new members.
-- SECURITY DEFINER because bootstrapping a brand-new room's first members
-- (or a full membership replace) can't satisfy chats.is_chat_member() via
-- RLS alone -- the caller isn't a member of a room that doesn't have any
-- members yet. The check below replicates what RLS would enforce: either
-- the caller is already a member, or the room currently has none (fresh
-- room, being seeded for the first time).
CREATE OR REPLACE FUNCTION chats.replace_room_members(room_id uuid, members jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ''
AS $$
BEGIN
    IF NOT (
        chats.is_chat_member(room_id)
        OR NOT EXISTS (SELECT 1 FROM chats.room_members WHERE "roomId" = room_id)
    ) THEN
        RAISE EXCEPTION 'not a member of this room';
    END IF;

    DELETE FROM chats.room_members WHERE "roomId" = room_id;

    INSERT INTO chats.room_members ("roomId", "userId", role)
    SELECT room_id, (m ->> 'id')::uuid, m ->> 'role'
    FROM jsonb_array_elements(members) AS m;
END;
$$;

REVOKE ALL ON FUNCTION chats.replace_room_members(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION chats.replace_room_members(uuid, jsonb) TO authenticated;

CREATE POLICY "chats.users_grant_create"
    ON chats.users
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK (false); -- Created by trigger

CREATE POLICY "chats.users_grant_read"
    ON chats.users
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING (chats.is_auth());

CREATE POLICY "chats.users_grant_update"
    ON chats.users
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING (chats.is_auth())
    WITH CHECK (chats.is_owner(id));

CREATE POLICY "chats.users_grant_delete"
    ON chats.users
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING (false); -- Delete by foreign key

CREATE POLICY "chats.rooms_grant_create"
    ON chats.rooms
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK (chats.is_auth());

CREATE POLICY "chats.rooms_grant_read"
    ON chats.rooms
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING (chats.is_chat_member(id));

CREATE POLICY "chats.rooms_grant_update"
    ON chats.rooms
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING (chats.is_chat_member(id))
    WITH CHECK (chats.is_chat_member(id));

CREATE POLICY "chats.rooms_grant_delete"
    ON chats.rooms
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING (chats.is_chat_member(id));

-- INSERT: you can always add yourself (covers a brand-new room's creator,
-- and "joining" flows in general), or add someone else to a room you're
-- already a member of (group invites). Bulk-seeding a group's initial
-- members works because the creator's own row satisfies "userId = auth.uid()"
-- regardless of insert order.
CREATE POLICY "chats.room_members_grant_create"
    ON chats.room_members
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK (
        chats.is_auth()
        AND ("userId" = auth.uid() OR chats.is_chat_member("roomId"))
    );

CREATE POLICY "chats.room_members_grant_read"
    ON chats.room_members
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING (chats.is_chat_member("roomId"));

-- Covers both "leave a room" (deleting your own row) and "remove a member"
-- (an existing member deleting someone else's row).
CREATE POLICY "chats.room_members_grant_delete"
    ON chats.room_members
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING (chats.is_chat_member("roomId"));

CREATE POLICY "chats.messages_grant_create"
    ON chats.messages
    AS PERMISSIVE
    FOR INSERT
    TO public
    WITH CHECK (chats.is_chat_member("roomId"));

CREATE POLICY "chats.messages_grant_read"
    ON chats.messages
    AS PERMISSIVE
    FOR SELECT
    TO public
    USING (chats.is_chat_member("roomId"));

CREATE POLICY "chats.messages_grant_update"
    ON chats.messages
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING (chats.is_chat_member("roomId"))
    WITH CHECK (chats.is_chat_member("roomId"));

CREATE POLICY "chats.messages_grant_delete"
    ON chats.messages
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING (chats.is_chat_member("roomId"));
