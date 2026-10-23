-- Storage buckets and policies for chat attachments and user avatars.
--
--   chats_assets/<roomId>/<file>       readable and uploadable by room
--                                      members; overwritten only by its
--                                      uploader, deleted by its uploader or
--                                      a group admin (the same rules as the
--                                      message it belongs to).
--   chats_user_avatar/<userId>/<file>  readable by any authenticated user,
--                                      writable by its owner only.
--
-- Both buckets are private: files are served through authenticated URLs
-- (`/storage/v1/object/authenticated/...`) with the user's access token.
-- Requires 03_database_policy.sql (path helpers) to have run first.
insert into storage.buckets
  (id, name)
values
  ('chats_assets', 'chats_assets'),
  ('chats_user_avatar', 'chats_user_avatar')
on conflict (id) do nothing;

DROP policy IF EXISTS "storage.object_grant_create_auth_chats_assets"
    ON storage.objects;
create policy "storage.object_grant_create_auth_chats_assets"
on storage.objects for insert
to authenticated
with check (
    bucket_id = 'chats_assets'
    and
    chats.is_chat_member_path(name));

DROP policy IF EXISTS "storage.object_grant_read_auth_chats_assets"
    ON storage.objects;
create policy "storage.object_grant_read_auth_chats_assets"
on storage.objects for select
to authenticated
using (
    bucket_id = 'chats_assets'
    and
    chats.is_chat_member_path(name));

DROP policy IF EXISTS "storage.object_grant_update_auth_chats_assets"
    ON storage.objects;
-- An attachment backs its author's message, which only the author may edit:
-- another member overwriting it (upsert) would change what the message
-- shows under its author's name.
create policy "storage.object_grant_update_auth_chats_assets"
on storage.objects for update
to authenticated
using (
    bucket_id = 'chats_assets'
    and
    owner_id = (select auth.uid()::text)
    and
    chats.is_chat_member_path(name))
with check (
    bucket_id = 'chats_assets'
    and
    owner_id = (select auth.uid()::text)
    and
    chats.is_chat_member_path(name));

DROP policy IF EXISTS "storage.object_grant_delete_auth_chats_assets"
    ON storage.objects;
create policy "storage.object_grant_delete_auth_chats_assets"
on storage.objects for delete
to authenticated
using (
    bucket_id = 'chats_assets'
    and
    chats.is_chat_member_path(name)
    and
    (owner_id = (select auth.uid()::text) or chats.is_chat_admin_path(name)));

DROP policy IF EXISTS "storage.object_grant_create_auth_chats_user_avatar"
    ON storage.objects;
create policy "storage.object_grant_create_auth_chats_user_avatar"
on storage.objects for insert
to authenticated
with check (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_owner_path(name));

DROP policy IF EXISTS "storage.object_grant_read_auth_chats_user_avatar"
    ON storage.objects;
create policy "storage.object_grant_read_auth_chats_user_avatar"
on storage.objects for select
to authenticated
using (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_auth());

DROP policy IF EXISTS "storage.object_grant_update_auth_chats_user_avatar"
    ON storage.objects;
create policy "storage.object_grant_update_auth_chats_user_avatar"
on storage.objects for update
to authenticated
using (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_owner_path(name))
with check (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_owner_path(name));

DROP policy IF EXISTS "storage.object_grant_delete_auth_chats_user_avatar"
    ON storage.objects;
create policy "storage.object_grant_delete_auth_chats_user_avatar"
on storage.objects for delete
to authenticated
using (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_owner_path(name));
