DROP POLICY IF EXISTS "chats.users_grant_create" ON chats.users;
DROP POLICY IF EXISTS "chats.users_grant_read" ON chats.users;
DROP POLICY IF EXISTS "chats.users_grant_update" ON chats.users;
DROP POLICY IF EXISTS "chats.users_grant_delete" ON chats.users;

DROP POLICY IF EXISTS "chats.rooms_grant_create" ON chats.rooms;
DROP POLICY IF EXISTS "chats.rooms_grant_read" ON chats.rooms;
DROP POLICY IF EXISTS "chats.rooms_grant_update" ON chats.rooms;
DROP POLICY IF EXISTS "chats.rooms_grant_delete" ON chats.rooms;

DROP POLICY IF EXISTS "chats.messages_grant_create" ON chats.messages;
DROP POLICY IF EXISTS "chats.messages_grant_read" ON chats.messages;
DROP POLICY IF EXISTS "chats.messages_grant_update" ON chats.messages;
DROP POLICY IF EXISTS "chats.messages_grant_delete" ON chats.messages;

DROP function if exists chats.is_auth;
CREATE OR REPLACE FUNCTION chats.is_auth()
    RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY DEFINER
AS $BODY$
BEGIN
  return auth.uid() IS NOT NULL;
end;
$BODY$;

DROP function if exists chats.is_owner;
CREATE OR REPLACE FUNCTION chats.is_owner(user_id uuid)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY DEFINER
AS $BODY$
BEGIN
  return auth.uid() = user_id;
end;
$BODY$;

DROP function if exists chats.is_member;
CREATE OR REPLACE FUNCTION chats.is_member(members uuid[])
    RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY DEFINER
AS $BODY$
BEGIN
  return auth.uid() = ANY(members);
end;
$BODY$;

DROP function if exists chats.is_chat_member;
CREATE OR REPLACE FUNCTION chats.is_chat_member(room_id bigint)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE NOT LEAKPROOF SECURITY DEFINER
AS $BODY$
DECLARE
  members uuid[];
BEGIN
    SELECT "userIds" INTO members
      FROM chats.rooms
      WHERE id = room_id;
  return chats.is_member(members);
end;
$BODY$;

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
    USING (chats.is_member("userIds"));

CREATE POLICY "chats.rooms_grant_update"
    ON chats.rooms
    AS PERMISSIVE
    FOR UPDATE
    TO public
    USING (chats.is_member("userIds"))
    WITH CHECK (chats.is_member("userIds"));

CREATE POLICY "chats.rooms_grant_delete"
    ON chats.rooms
    AS PERMISSIVE
    FOR DELETE
    TO public
    USING (chats.is_member("userIds"));

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