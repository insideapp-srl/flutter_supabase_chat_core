---
id: supabase-security
title: Security Rules
---

`example/utils/sql/03_database_policy.sql` and `04_storage.sql` protect every table, bucket and Realtime channel with [Postgres Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security). Both scripts are idempotent: every function is replaced and every policy dropped and recreated.

## Access model

* **`chats.users`**: readable by any authenticated user, updatable by its owner only, created and deleted by triggers/foreign keys only.
* **`chats.rooms`**: readable by members. Created only through `chats.create_room()` (room and members in one transaction, direct rooms de-duplicated). Group rooms are renamed and deleted by their admins, direct rooms by either member.
* **`chats.room_members`**: readable by members of the same room. Group admins add and remove members and change roles; anyone can leave a room. Nobody can add themselves: knowing a room's id is not enough to join it.
* **`chats.messages`**: readable by members; a message can only be sent as yourself, edited by its author, and deleted by its author or a group admin.
* Read receipts, reactions, pins and per-user preferences touch rows of other people (or columns clients may not write), so they go through `SECURITY DEFINER` RPCs that check membership themselves.

"Admin" means a member with role `admin` in a **group** room. In a **direct** room both members have the same rights over it, so the admin helper is true for either of them.

## Helper functions

```sql
-- auth.uid() IS NOT NULL / auth.uid() = user_id
CREATE OR REPLACE FUNCTION chats.is_auth() ...
CREATE OR REPLACE FUNCTION chats.is_owner(user_id uuid) ...

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

-- Admin of a group room, or member of a direct room.
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

-- The caller's role in a room ('admin', 'moderator', or NULL).
CREATE OR REPLACE FUNCTION chats.chat_member_role(room_id uuid) ...
```

Path and topic helpers never raise on malformed input (a bare `::uuid` cast inside a policy could fail queries on unrelated rows, since SQL doesn't guarantee the evaluation order of AND-ed conditions):

* `chats.is_chat_member_path(object_name)`: is the caller a member of the room whose id is the first folder of a `chats_assets` path? Folders named after a 1.x numeric room id are resolved through `chats.room_id_migration_map`, so attachments uploaded before the migration stay readable until `migrate_storage_uuids` moves them (see MIGRATION.md).
* `chats.is_owner_path(object_name)`: is the first folder the caller's own user id?
* `chats.is_chat_member_topic(topic)`: is the caller a member of the room of a `chats:room:<roomId>` Realtime topic? False for any other topic.

## Tables

| Table | INSERT | SELECT | UPDATE | DELETE |
|-------|--------|--------|--------|--------|
| `chats.users` | Nobody (sign-up trigger) | Authenticated users | Owner | Nobody (deleted with `auth.users`) |
| `chats.rooms` | Nobody (`chats.create_room`) | Members | Admins | Admins |
| `chats.room_members` | Group admins, group rooms only | Members of the same room | Admins | Yourself, or admins |
| `chats.messages` | Members, as themselves | Members | Author | Author, or group admin |

### `chats.users`

```sql
CREATE POLICY "chats.users_grant_create" ON chats.users
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (false); -- Created by trigger

CREATE POLICY "chats.users_grant_read" ON chats.users
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (chats.is_auth());

CREATE POLICY "chats.users_grant_update" ON chats.users
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (chats.is_owner(id));

CREATE POLICY "chats.users_grant_delete" ON chats.users
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (false); -- Delete by foreign key
```

### `chats.rooms`

```sql
CREATE POLICY "chats.rooms_grant_create" ON chats.rooms
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (false); -- Created by chats.create_room()

CREATE POLICY "chats.rooms_grant_read" ON chats.rooms
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (chats.is_chat_member(id));

CREATE POLICY "chats.rooms_grant_update" ON chats.rooms
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (chats.is_chat_admin(id));

CREATE POLICY "chats.rooms_grant_delete" ON chats.rooms
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (chats.is_chat_admin(id));
```

### `chats.room_members`

```sql
-- Only group admins add members, and only to group rooms (a direct room's
-- membership is fixed at creation). No "add yourself" path.
CREATE POLICY "chats.room_members_grant_create" ON chats.room_members
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (
        chats.is_chat_admin("roomId")
        AND EXISTS (SELECT 1 FROM chats.rooms r WHERE r.id = "roomId" AND r.type = 'group')
    );

CREATE POLICY "chats.room_members_grant_read" ON chats.room_members
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (chats.is_chat_member("roomId"));

-- Role changes ("lastReadAt", "pinnedAt", "mutedUntil" go through RPCs).
CREATE POLICY "chats.room_members_grant_update" ON chats.room_members
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (chats.is_chat_admin("roomId"));

-- Leave a room (your own row) or remove a member (admins).
CREATE POLICY "chats.room_members_grant_delete" ON chats.room_members
    AS PERMISSIVE FOR DELETE TO authenticated
    USING ("userId" = (SELECT auth.uid()) OR chats.is_chat_admin("roomId"));
```

A room left without members is deleted by the `delete_room_if_empty` trigger (see [Database Triggers](supabse-trigges.md)).

### `chats.messages`

```sql
CREATE POLICY "chats.messages_grant_create" ON chats.messages
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (chats.is_chat_member("roomId") AND "authorId" = (SELECT auth.uid()));

CREATE POLICY "chats.messages_grant_read" ON chats.messages
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (chats.is_chat_member("roomId"));

CREATE POLICY "chats.messages_grant_update" ON chats.messages
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (chats.is_chat_member("roomId") AND "authorId" = (SELECT auth.uid()));

CREATE POLICY "chats.messages_grant_delete" ON chats.messages
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (
        chats.is_chat_member("roomId")
        AND ("authorId" = (SELECT auth.uid()) OR chats.chat_member_role("roomId") = 'admin')
    );
```

UPDATE policies state their rule once, in `USING`: without `WITH CHECK`, Postgres applies the `USING` expression to the new row too, so a row can neither be selected nor moved outside of the rule.

Enabling RLS on a partitioned table doesn't apply to partitions created later, so `chats.ensure_messages_partitions_rls()` enables it on every `chats.messages` partition and revokes their direct grants (partitions are only reached through the parent). It runs after the scripts and hourly with the `pg_cron` partition maintenance.

## RPCs

All `SECURITY DEFINER` (they bypass RLS), so each one checks the caller itself:

| Function | Checks | Does |
|----------|--------|------|
| `chats.create_room(p_type, p_user_ids, p_name, p_image_url, p_metadata, p_creator_role)` | Logged in, valid type, known users, exactly one other user for `direct` | Creates the room and its members (the caller always included, with `p_creator_role` in groups); returns an existing direct room for the same pair and metadata scope, serialized with an advisory lock |
| `chats.mark_room_as_read(p_room_id)` | Member | Stores the caller's `lastReadAt` and flips the other members' messages to `seen` |
| `chats.toggle_message_reaction(p_message_id, p_reaction)` | Member, reaction of 1–64 characters | Adds/removes the caller's reaction atomically; returns the reactions map |
| `chats.pin_room(p_room_id, p_pinned)` | Member | Sets the caller's own `pinnedAt` |
| `chats.mute_room(p_room_id, p_until)` | Member | Sets the caller's own `mutedUntil` (`'infinity'` for ever, `NULL` to unmute) |
| `chats.set_message_pinned(p_message_id, p_pinned)` | Admin (either member of a direct room) | Pins/unpins a message for everyone |

## Realtime

Room channels (`chats:room:<roomId>`) are private. Members may join them (receive the message changes and typing events) and send Broadcast messages to them; nobody else can:

```sql
CREATE POLICY "chats.realtime_room_read" ON realtime.messages
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (chats.is_chat_member_topic((SELECT realtime.topic())));

CREATE POLICY "chats.realtime_room_write" ON realtime.messages
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (
        extension = 'broadcast'
        AND chats.is_chat_member_topic((SELECT realtime.topic()))
    );
```

See [Realtime](supabase-realtime.md).

## Storage buckets

Both buckets are private; files are served through authenticated URLs (`/storage/v1/object/authenticated/...`) with the user's access token.

| Bucket | INSERT | SELECT | UPDATE | DELETE |
|--------|--------|--------|--------|--------|
| `chats_assets` (`<roomId>/<file>`) | Room members | Room members | Room members | Room members |
| `chats_user_avatar` (`<uid>/<file>`) | Owner | Authenticated users | Owner | Owner |

```sql
create policy "storage.object_grant_read_auth_chats_assets"
on storage.objects for select
to authenticated
using (
    bucket_id = 'chats_assets'
    and
    chats.is_chat_member_path(name));

create policy "storage.object_grant_create_auth_chats_user_avatar"
on storage.objects for insert
to authenticated
with check (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_owner_path(name));

create policy "storage.object_grant_read_auth_chats_user_avatar"
on storage.objects for select
to authenticated
using (
    bucket_id = 'chats_user_avatar'
    and
    chats.is_auth());
```

The other `chats_assets` policies use `chats.is_chat_member_path(name)` and the other avatar policies `chats.is_owner_path(name)` in the same way.

## Privileges

The policies target `authenticated` only: `anon` gets no chat rows (instead
of an error) and the helpers they call don't need to be executable by `anon`.
`99_database_schema_permission.sql` therefore revokes `EXECUTE` on the policy
helpers from `anon`, and on the trigger functions from every client role, so
none of them can be called through `/rest/v1/rpc`. The `auth.uid()` checks
are written `(SELECT auth.uid())`, evaluated once per query instead of once
per row.

With the scripts applied, the Supabase Security and Performance Advisors only
report what is intended: the RPCs and policy helpers executable by
`authenticated` (they check the caller themselves), the tables closed on
purpose with RLS and no policy (partitions, internal queues, 1.x backups),
and the indexes not used yet on a new project.

## Internal tables

* `chats.media_pending_deletion` (the media cleanup queue) has RLS enabled and no policies: only `SECURITY DEFINER` functions and the `service_role` (the `cleanup-media` Edge Function) reach it.
* `chats.room_id_migration_map` (1.x → 2.x room ids, only present after a migration, dropped by `migrate_storage_uuids` once the attachments are moved) is internal bookkeeping read by `chats.is_chat_member_path`.
* After a 1.x migration, the `*_backup_<ts>` tables keep RLS enabled with their policies dropped, so they are closed to clients.

:::caution
The client-side scoping hooks of `SupabaseChatCoreConfig` (workspaces, organizations) only filter what the app asks for. If a scope is a security boundary, add the same rule to these policies.
:::

To learn more head over to the [Postgres Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security) guide.
