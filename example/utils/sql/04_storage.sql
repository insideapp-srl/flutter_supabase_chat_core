insert into storage.buckets
  (id, name)
values
  ('chats_assets', 'chats_assets'),
  ('chats_user_avatar', 'chats_user_avatar');

DROP policy IF EXISTS "storage.object_grant_create_auth_chats_assets"
    ON storage.objects;
create policy "storage.object_grant_create_auth_chats_assets"
on storage.objects for insert
with check (
    bucket_id = 'chats_assets'
    and
    chats.is_chat_member((storage.foldername(name))[1]::bigint));

DROP policy IF EXISTS "storage.object_grant_read_auth_chats_assets"
    ON storage.objects;
create policy "storage.object_grant_read_auth_chats_assets"
on storage.objects for select
using (
    bucket_id = 'chats_assets'
    and
    chats.is_chat_member((storage.foldername(name))[1]::bigint));

DROP policy IF EXISTS "storage.object_grant_update_auth_chats_assets"
    ON storage.objects;
create policy "storage.object_grant_update_auth_chats_assets"
on storage.objects for update
using (
    bucket_id = 'chats_assets'
    and
    chats.is_chat_member((storage.foldername(name))[1]::bigint))
with check (
    bucket_id = 'chats_assets'
    and
    chats.is_chat_member((storage.foldername(name))[1]::bigint));

DROP policy IF EXISTS "storage.object_grant_delete_auth_chats_assets"
    ON storage.objects;
create policy "storage.object_grant_delete_auth_chats_assets"
on storage.objects for delete
using (
    bucket_id = 'chats_assets'
    and
    chats.is_chat_member((storage.foldername(name))[1]::bigint));

DROP policy IF EXISTS "storage.object_grant_create_auth_chats_user_avatar"
    ON storage.objects;
create policy "storage.object_grant_create_auth_chats_user_avatar"
on storage.objects for insert
with check (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_owner((storage.foldername(name))[1]::uuid));

DROP policy IF EXISTS "storage.object_grant_read_auth_chats_user_avatar"
    ON storage.objects;
create policy "storage.object_grant_read_auth_chats_user_avatar"
on storage.objects for select
using (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_auth());

DROP policy IF EXISTS "storage.object_grant_update_auth_chats_user_avatar"
    ON storage.objects;
create policy "storage.object_grant_update_auth_chats_user_avatar"
on storage.objects for update
using (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_owner((storage.foldername(name))[1]::uuid))
with check (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_owner((storage.foldername(name))[1]::uuid));

DROP policy IF EXISTS "storage.object_grant_delete_auth_chats_user_avatar"
    ON storage.objects;
create policy "storage.object_grant_delete_auth_chats_user_avatar"
on storage.objects for delete
using (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_owner((storage.foldername(name))[1]::uuid));
