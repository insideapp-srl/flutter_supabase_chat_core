GRANT USAGE ON SCHEMA chats TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA chats TO anon, authenticated, service_role;
GRANT ALL ON ALL ROUTINES IN SCHEMA chats TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA chats TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA chats GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA chats GRANT ALL ON ROUTINES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA chats GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

-- The blanket grants above reopen what the previous scripts closed on
-- purpose: close it again. Internal tables (migration map, media cleanup
-- queue) stay service_role only, and the RPCs need a signed-in user.
DO $do$
BEGIN
    IF to_regclass('chats.room_id_migration_map') IS NOT NULL THEN
        REVOKE ALL ON TABLE chats.room_id_migration_map FROM anon, authenticated;
    END IF;
END
$do$;
REVOKE ALL ON TABLE chats.media_pending_deletion FROM anon, authenticated;
REVOKE ALL ON TABLE chats.message_ids FROM anon, authenticated;

-- Column privileges: UPDATE policies say which rows a user may change, these
-- say which columns. Without them a room admin (or either member of a direct
-- room) could rewrite a membership's room or user, or a room's type, and
-- reach states the INSERT rules forbid (e.g. a third member in a direct
-- room); a user could set their own global role.
REVOKE UPDATE ON TABLE chats.rooms FROM anon, authenticated;
GRANT UPDATE (name, "imageUrl", metadata, "updatedAt") ON TABLE chats.rooms TO authenticated;
REVOKE UPDATE ON TABLE chats.room_members FROM anon, authenticated;
GRANT UPDATE (role) ON TABLE chats.room_members TO authenticated;
REVOKE UPDATE ON TABLE chats.users FROM anon, authenticated;
GRANT UPDATE ("firstName", "lastName", "imageUrl", metadata, "updatedAt", "lastSeen") ON TABLE chats.users TO authenticated;
REVOKE ALL ON FUNCTION chats.create_room(text, uuid[], text, text, jsonb, text) FROM anon;
REVOKE ALL ON FUNCTION chats.mark_room_as_read(uuid) FROM anon;
REVOKE ALL ON FUNCTION chats.toggle_message_reaction(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION chats.pin_room(uuid, boolean) FROM anon;
REVOKE ALL ON FUNCTION chats.mute_room(uuid, timestamptz) FROM anon;
REVOKE ALL ON FUNCTION chats.set_message_pinned(uuid, boolean) FROM anon;

-- Trigger functions run whatever the caller's privileges (EXECUTE is only
-- checked when the trigger is created): nobody needs to call them through
-- /rest/v1/rpc. The policy helpers stay callable by authenticated users (the
-- policies run as the caller) but not by anon, which no chat policy targets.
REVOKE ALL ON FUNCTION chats.handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.update_last_messages() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.set_message_status_to_sent() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.protect_message_columns() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.attest_forward_origin() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.claim_message_id() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.queue_media_for_deletion() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.delete_room_if_empty() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.broadcast_message_change() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.send_room_change(uuid, uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.broadcast_members_upserted() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.broadcast_members_updated() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.broadcast_members_deleted() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.broadcast_rooms_updated() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.ensure_messages_partitions_rls() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.secure_new_messages_partitions() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.is_chat_member(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.is_chat_admin(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.chat_member_role(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.room_id_from_path(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.is_chat_member_path(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.is_chat_admin_path(text) FROM PUBLIC, anon;

-- The blanket grants above also reach the chats.messages partitions, which
-- must only be accessed through the parent table: take them back.
SELECT chats.ensure_messages_partitions_rls();
