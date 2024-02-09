---
id: supabase-security
title: Security Rules
---

This is a drop-in example of [Postgres Row Security Level](https://supabase.com/docs/guides/database/postgres/row-level-security) designed for a typical chat application.

# Helper functions

Security rules make use of some helper functions:

```sql
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
```
# Security rules 

## Tables

### Summary

#### Table `chats.users`

- `INSERT` : Nobody, this table is populate by trigger on auth.users.
- `SELECT` : All users authenticated.
- `UPDATE` : Only the user himself.
- `DELETE` : Nobody.

#### Table `chats.rooms`

- `INSERT` : All users authenticated.
- `SELECT` : All users who are members of the chat room.
- `UPDATE` : All users who are members of the chat room.
- `DELETE` : All users who are members of the chat room.

#### Table `chats.messages`

- `INSERT` : All users who are members of the chat room.
- `SELECT` : All users who are members of the chat room.
- `UPDATE` : All users who are members of the chat room.
- `DELETE` : All users who are members of the chat room.

---

Security rules implemented:

### Table `users`

```sql
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
```

### Table `rooms`

```sql
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
```

### Table `messages`

```sql
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
```

## Storage buckets

### Summary

#### Bucket `chats_assets`

- `INSERT` : All users who are members of the chat room.
- `SELECT` : All users who are members of the chat room.
- `UPDATE` : All users who are members of the chat room.
- `DELETE` : All users who are members of the chat room.

#### Bucket `chats_user_avatar`

- `INSERT` : Only the user himself.
- `SELECT` : All users authenticated.
- `UPDATE` : Only the user himself.
- `DELETE` : Only the user himself.

---

Security rules implemented:

### Bucket `chats_assets`

```sql
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
```

### Bucket `chats_user_avatar`

```sql
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
```

To learn more head over to the [Postgres Row Security Level](https://supabase.com/docs/guides/database/postgres/row-level-security) website.
