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
REVOKE ALL ON FUNCTION chats.queue_media_for_deletion() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.delete_room_if_empty() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.broadcast_message_change() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.ensure_messages_partitions_rls() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION chats.is_chat_member(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.is_chat_admin(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.chat_member_role(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION chats.is_chat_member_path(text) FROM PUBLIC, anon;

-- The blanket grants above also reach the chats.messages partitions, which
-- must only be accessed through the parent table: take them back.
SELECT chats.ensure_messages_partitions_rls();
