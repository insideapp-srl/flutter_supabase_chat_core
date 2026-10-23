-- pgTAP behaviour tests for the chat schema (example/utils/sql).
-- Run against the local stack after tool/local_db.sh:
--   supabase test db
-- Everything runs in one transaction that is rolled back at the end.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = extensions, public;

SELECT plan(95);

-- ---------------------------------------------------------------------------
-- Fixtures: four auth users (the chats.users rows come from the trigger).
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (id, email, aud, role, raw_user_meta_data) VALUES
    ('fa000000-0000-0000-0000-000000000001', 'alice@test.dev', 'authenticated', 'authenticated', '{"first_name":"Alice","last_name":"Liddell"}'),
    ('fb000000-0000-0000-0000-000000000002', 'bob@test.dev',   'authenticated', 'authenticated', '{"first_name":"Bob","last_name":"Builder"}'),
    ('fc000000-0000-0000-0000-000000000003', 'carol@test.dev', 'authenticated', 'authenticated', '{"given_name":"Carol"}'),
    ('fd000000-0000-0000-0000-000000000004', 'dave@test.dev',  'authenticated', 'authenticated', NULL);

CREATE TEMP TABLE ids (k text PRIMARY KEY, v uuid) ON COMMIT DROP;
GRANT ALL ON ids TO authenticated;

CREATE FUNCTION pg_temp.login(uid uuid) RETURNS void LANGUAGE sql AS $$
    SELECT set_config('role', 'authenticated', true),
           set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;
CREATE FUNCTION pg_temp.logout() RETURNS void LANGUAGE sql AS $$
    SELECT set_config('role', 'postgres', true),
           set_config('request.jwt.claims', '', true);
$$;

-- ---------------------------------------------------------------------------
-- handle_new_user
-- ---------------------------------------------------------------------------
SELECT is((SELECT count(*)::int FROM chats.users WHERE id::text ~ '^f[a-d]000000-'), 4, 'a chats.users row is created for every auth user');
SELECT is((SELECT "firstName" || ' ' || "lastName" FROM chats.users WHERE id = 'fa000000-0000-0000-0000-000000000001'),
          'Alice Liddell', 'names are taken from sign-up metadata');
SELECT is((SELECT "firstName" FROM chats.users WHERE id = 'fc000000-0000-0000-0000-000000000003'),
          'Carol', 'OAuth-style given_name is supported');
SELECT is((SELECT "firstName" FROM chats.users WHERE id = 'fd000000-0000-0000-0000-000000000004'),
          NULL, 'missing metadata leaves names empty');

-- ---------------------------------------------------------------------------
-- chats.users RLS
-- ---------------------------------------------------------------------------
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
SELECT is((SELECT count(*)::int FROM chats.users WHERE id::text ~ '^f[a-d]000000-'), 4, 'authenticated users can read every profile');
UPDATE chats.users SET "firstName" = 'Al' WHERE id = 'fa000000-0000-0000-0000-000000000001';
UPDATE chats.users SET "firstName" = 'Hacked' WHERE id = 'fb000000-0000-0000-0000-000000000002';
SELECT pg_temp.logout();
SELECT is((SELECT "firstName" FROM chats.users WHERE id = 'fa000000-0000-0000-0000-000000000001'), 'Al', 'a user can update its own profile');
SELECT is((SELECT "firstName" FROM chats.users WHERE id = 'fb000000-0000-0000-0000-000000000002'), 'Bob', 'a user cannot update someone else''s profile');

SET LOCAL role anon;
SELECT is((SELECT count(*)::int FROM chats.users), 0, 'anon cannot read profiles');
RESET role;

-- ---------------------------------------------------------------------------
-- create_room: direct
-- ---------------------------------------------------------------------------
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
SELECT throws_ok($$INSERT INTO chats.rooms (type) VALUES ('group')$$, '42501', NULL, 'rooms cannot be inserted directly');

INSERT INTO ids SELECT 'direct_ab', chats.create_room('direct', ARRAY['fb000000-0000-0000-0000-000000000002']::uuid[]);
SELECT isnt((SELECT v FROM ids WHERE k = 'direct_ab'), NULL, 'create_room returns the new direct room id');
SELECT is(chats.create_room('direct', ARRAY['fb000000-0000-0000-0000-000000000002']::uuid[]),
          (SELECT v FROM ids WHERE k = 'direct_ab'), 'an existing direct room is reused');
SELECT pg_temp.login('fb000000-0000-0000-0000-000000000002');
SELECT is(chats.create_room('direct', ARRAY['fa000000-0000-0000-0000-000000000001']::uuid[]),
          (SELECT v FROM ids WHERE k = 'direct_ab'), 'the direct room is reused from the other side too');
INSERT INTO ids SELECT 'direct_ab_ws', chats.create_room('direct', ARRAY['fa000000-0000-0000-0000-000000000001']::uuid[], p_metadata => '{"workspaceId":"w1"}');
SELECT isnt((SELECT v FROM ids WHERE k = 'direct_ab_ws'), (SELECT v FROM ids WHERE k = 'direct_ab'),
            'a direct room in another metadata scope is a different room');
SELECT is(chats.create_room('direct', ARRAY['fa000000-0000-0000-0000-000000000001']::uuid[], p_metadata => '{"workspaceId":"w1"}'),
          (SELECT v FROM ids WHERE k = 'direct_ab_ws'), 'the scoped direct room is reused within its scope');
SELECT throws_ok($$SELECT chats.create_room('direct', ARRAY['fa000000-0000-0000-0000-000000000001','fc000000-0000-0000-0000-000000000003']::uuid[])$$,
                 '22023', NULL, 'a direct room needs exactly two members');
SELECT throws_ok($$SELECT chats.create_room('direct', ARRAY['eeeeeeee-0000-0000-0000-000000000000']::uuid[])$$,
                 '23503', NULL, 'unknown users are rejected');
SELECT throws_ok($$SELECT chats.create_room('channel', ARRAY[]::uuid[])$$, '22023', NULL, 'unknown room types are rejected');

SELECT pg_temp.logout();
SELECT throws_ok($$SELECT chats.create_room('group', ARRAY[]::uuid[])$$, '42501', NULL, 'create_room requires a logged in user');

-- ---------------------------------------------------------------------------
-- create_room: group, rooms_l
-- ---------------------------------------------------------------------------
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
INSERT INTO ids SELECT 'group_abc', chats.create_room('group',
    ARRAY['fb000000-0000-0000-0000-000000000002','fc000000-0000-0000-0000-000000000003']::uuid[], 'Team', NULL, '{"color":"red"}');
SELECT is((SELECT role FROM chats.room_members WHERE "roomId" = (SELECT v FROM ids WHERE k = 'group_abc') AND "userId" = auth.uid()),
          'admin', 'the group creator is admin');
SELECT is((SELECT count(*)::int FROM chats.room_members WHERE "roomId" = (SELECT v FROM ids WHERE k = 'group_abc')),
          3, 'every group member is added');
SELECT is((SELECT name FROM chats.rooms_l WHERE id = (SELECT v FROM ids WHERE k = 'direct_ab')),
          'Bob Builder', 'rooms_l names a direct room after the other member');
SELECT is((SELECT jsonb_array_length(users) FROM chats.rooms_l WHERE id = (SELECT v FROM ids WHERE k = 'group_abc')),
          3, 'rooms_l embeds the members');
SELECT is((SELECT count(*)::int FROM chats.rooms_l), 3, 'alice sees her three rooms only');

SELECT pg_temp.login('fd000000-0000-0000-0000-000000000004');
SELECT is((SELECT count(*)::int FROM chats.rooms), 0, 'non-members see no rooms');
SELECT is((SELECT count(*)::int FROM chats.room_members), 0, 'non-members see no memberships');
SELECT throws_ok(format($$INSERT INTO chats.room_members ("roomId", "userId") VALUES (%L, auth.uid())$$, (SELECT v FROM ids WHERE k = 'group_abc')),
                 '42501', NULL, 'knowing a room id is not enough to join it');

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
INSERT INTO ids VALUES ('m1', 'f0000000-0000-0000-0000-000000000001');
SELECT lives_ok(format($$INSERT INTO chats.messages (id, "roomId", "authorId", type, text, status, "createdAt")
                         VALUES ('f0000000-0000-0000-0000-000000000001', %L, auth.uid(), 'text', 'hello', 'sending', now() - interval '1 minute')$$,
                        (SELECT v FROM ids WHERE k = 'group_abc')),
                'a member can send a message');
SELECT is((SELECT status FROM chats.messages WHERE id = 'f0000000-0000-0000-0000-000000000001'), 'sent', 'inserted messages are marked sent');
SELECT throws_ok(format($$INSERT INTO chats.messages ("roomId", "authorId", type, text) VALUES (%L, 'fb000000-0000-0000-0000-000000000002', 'text', 'spoof')$$,
                        (SELECT v FROM ids WHERE k = 'group_abc')),
                 '42501', NULL, 'a message cannot be sent on behalf of someone else');
SELECT is((SELECT "lastMessages" -> 0 ->> 'text' FROM chats.rooms WHERE id = (SELECT v FROM ids WHERE k = 'group_abc')),
          'hello', 'the room keeps a snapshot of its last message');

SELECT pg_temp.login('fb000000-0000-0000-0000-000000000002');
SELECT is((SELECT "unreadCount" FROM chats.rooms_l WHERE id = (SELECT v FROM ids WHERE k = 'group_abc')), 1, 'bob has one unread message');
UPDATE chats.messages SET text = 'edited by bob' WHERE id = 'f0000000-0000-0000-0000-000000000001';
DELETE FROM chats.messages WHERE id = 'f0000000-0000-0000-0000-000000000001';
SELECT is((SELECT text FROM chats.messages WHERE id = 'f0000000-0000-0000-0000-000000000001'), 'hello',
          'only the author can edit, and a plain member cannot delete someone else''s message');

SELECT lives_ok($$SELECT chats.toggle_message_reaction('f0000000-0000-0000-0000-000000000001', '👍')$$, 'a member can react');
SELECT pg_temp.login('fc000000-0000-0000-0000-000000000003');
SELECT is(chats.toggle_message_reaction('f0000000-0000-0000-0000-000000000001', '👍') -> '👍',
          '["fb000000-0000-0000-0000-000000000002", "fc000000-0000-0000-0000-000000000003"]'::jsonb, 'reactions accumulate per user');
SELECT is(chats.toggle_message_reaction('f0000000-0000-0000-0000-000000000001', '👍') -> '👍',
          '["fb000000-0000-0000-0000-000000000002"]'::jsonb, 'reacting again removes the reaction');
SELECT pg_temp.login('fd000000-0000-0000-0000-000000000004');
SELECT throws_ok($$SELECT chats.toggle_message_reaction('f0000000-0000-0000-0000-000000000001', '👍')$$, 'P0002', NULL, 'non-members cannot react');
SELECT throws_ok(format($$SELECT chats.mark_room_as_read(%L)$$, (SELECT v FROM ids WHERE k = 'group_abc')), '42501', NULL, 'non-members cannot mark a room as read');
SELECT is((SELECT count(*)::int FROM chats.messages), 0, 'non-members cannot read messages');

SELECT pg_temp.login('fb000000-0000-0000-0000-000000000002');
CREATE TEMP TABLE times ON COMMIT DROP AS
    SELECT "updatedAt" AS t FROM chats.rooms WHERE id = (SELECT v FROM ids WHERE k = 'group_abc');
SELECT lives_ok(format($$SELECT chats.mark_room_as_read(%L)$$, (SELECT v FROM ids WHERE k = 'group_abc')), 'a member can mark a room as read');
SELECT is((SELECT "updatedAt" FROM chats.rooms WHERE id = (SELECT v FROM ids WHERE k = 'group_abc')), (SELECT t FROM times),
          'reading a room does not move it up the rooms list');
SELECT is((SELECT "unreadCount" FROM chats.rooms_l WHERE id = (SELECT v FROM ids WHERE k = 'group_abc')), 0, 'marking as read clears the unread count');
SELECT is((SELECT status FROM chats.messages WHERE id = 'f0000000-0000-0000-0000-000000000001'), 'seen', 'marking as read flips other members'' messages to seen');

-- ---------------------------------------------------------------------------
-- Per-member preferences and pinned messages
-- ---------------------------------------------------------------------------
SELECT lives_ok(format($$SELECT chats.pin_room(%L, true)$$, (SELECT v FROM ids WHERE k = 'group_abc')), 'a member can pin a room');
SELECT isnt((SELECT "pinnedAt" FROM chats.rooms_l WHERE id = (SELECT v FROM ids WHERE k = 'group_abc')), NULL, 'rooms_l exposes the own pin');
SELECT lives_ok(format($$SELECT chats.mute_room(%L, 'infinity')$$, (SELECT v FROM ids WHERE k = 'group_abc')), 'a member can mute a room for ever');
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
SELECT is((SELECT "pinnedAt" FROM chats.rooms_l WHERE id = (SELECT v FROM ids WHERE k = 'group_abc')), NULL, 'pins are per member');
SELECT pg_temp.login('fb000000-0000-0000-0000-000000000002');
SELECT throws_ok($$SELECT chats.set_message_pinned('f0000000-0000-0000-0000-000000000001', true)$$, '42501', NULL, 'plain group members cannot pin messages');
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
SELECT lives_ok($$SELECT chats.set_message_pinned('f0000000-0000-0000-0000-000000000001', true)$$, 'group admins can pin messages');
SELECT pg_temp.logout();
SELECT is((SELECT pinned FROM chats.messages WHERE id = 'f0000000-0000-0000-0000-000000000001'), true, 'the message is pinned');
SELECT pg_temp.login('fb000000-0000-0000-0000-000000000002');

-- ---------------------------------------------------------------------------
-- Room administration
-- ---------------------------------------------------------------------------
UPDATE chats.rooms SET name = 'Renamed by bob' WHERE id = (SELECT v FROM ids WHERE k = 'group_abc');
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
SELECT is((SELECT name FROM chats.rooms WHERE id = (SELECT v FROM ids WHERE k = 'group_abc')), 'Team', 'plain members cannot rename a group');
UPDATE chats.rooms SET name = 'Team 2' WHERE id = (SELECT v FROM ids WHERE k = 'group_abc');
SELECT is((SELECT name FROM chats.rooms WHERE id = (SELECT v FROM ids WHERE k = 'group_abc')), 'Team 2', 'admins can rename a group');
SELECT lives_ok(format($$INSERT INTO chats.room_members ("roomId", "userId") VALUES (%L, 'fd000000-0000-0000-0000-000000000004')$$, (SELECT v FROM ids WHERE k = 'group_abc')),
                'admins can add members');
SELECT throws_ok(format($$INSERT INTO chats.room_members ("roomId", "userId") VALUES (%L, 'fc000000-0000-0000-0000-000000000003')$$, (SELECT v FROM ids WHERE k = 'direct_ab')),
                 '42501', NULL, 'direct rooms membership is fixed');
UPDATE chats.room_members SET role = 'moderator' WHERE "roomId" = (SELECT v FROM ids WHERE k = 'group_abc') AND "userId" = 'fc000000-0000-0000-0000-000000000003';
SELECT is((SELECT role FROM chats.room_members WHERE "roomId" = (SELECT v FROM ids WHERE k = 'group_abc') AND "userId" = 'fc000000-0000-0000-0000-000000000003'),
          'moderator', 'admins can change roles');
SELECT lives_ok($$DELETE FROM chats.messages WHERE id = 'f0000000-0000-0000-0000-000000000001'$$, 'admins can delete any message of their group');
SELECT pg_temp.logout();
SELECT is((SELECT count(*)::int FROM chats.messages WHERE id = 'f0000000-0000-0000-0000-000000000001'), 0, 'the message is gone');

-- ---------------------------------------------------------------------------
-- Media cleanup queue and empty rooms
-- ---------------------------------------------------------------------------
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
INSERT INTO chats.messages ("roomId", "authorId", type, source, name, size)
VALUES ((SELECT v FROM ids WHERE k = 'direct_ab'), auth.uid(), 'file',
        'http://127.0.0.1:54321/storage/v1/object/authenticated/chats_assets/' || (SELECT v FROM ids WHERE k = 'direct_ab') || '/x.pdf', 'x.pdf', 1);
DELETE FROM chats.messages WHERE type = 'file';
SELECT pg_temp.logout();
SELECT is((SELECT "bucketId" || ':' || path FROM chats.media_pending_deletion WHERE path LIKE '%/x.pdf'),
          'chats_assets:' || (SELECT v FROM ids WHERE k = 'direct_ab') || '/x.pdf', 'deleting a media message queues its file for cleanup');

SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
DELETE FROM chats.room_members WHERE "roomId" = (SELECT v FROM ids WHERE k = 'direct_ab_ws') AND "userId" = auth.uid();
SELECT pg_temp.login('fb000000-0000-0000-0000-000000000002');
DELETE FROM chats.room_members WHERE "roomId" = (SELECT v FROM ids WHERE k = 'direct_ab_ws') AND "userId" = auth.uid();
SELECT pg_temp.logout();
SET CONSTRAINTS ALL IMMEDIATE;
SELECT is((SELECT count(*)::int FROM chats.rooms WHERE id = (SELECT v FROM ids WHERE k = 'direct_ab_ws')), 0, 'a room is deleted once its last member leaves');

-- ---------------------------------------------------------------------------
-- Storage policies
-- ---------------------------------------------------------------------------
SELECT pg_temp.login('fd000000-0000-0000-0000-000000000004');
SELECT is(chats.is_chat_member_path('not-a-uuid/file.png'), false, 'non-uuid folders are simply not members (no cast error)');
SELECT is(chats.is_owner_path(auth.uid()::text || '/avatar.png'), true, 'users own their avatar folder');
SELECT is(chats.is_chat_member_path((SELECT v FROM ids WHERE k = 'group_abc')::text || '/a.png'), true, 'room folders are open to members');

-- Realtime private channels
SELECT is(chats.is_chat_member_topic('chats:room:' || (SELECT v FROM ids WHERE k = 'group_abc')), true, 'members may join their room channel');
SELECT is(chats.is_chat_member_topic('chats:room:' || (SELECT v FROM ids WHERE k = 'direct_ab')), false, 'non-members may not join a room channel');
SELECT is(chats.is_chat_member_topic('chats:room:garbage'), false, 'malformed topics are rejected without errors');
SELECT is(chats.is_chat_member_topic('other:topic'), false, 'unrelated topics are left to other policies');
SELECT pg_temp.logout();

-- Partitions are reached only through chats.messages
SELECT is((SELECT count(*)::int FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
           WHERE i.inhparent = 'chats.messages'::regclass AND NOT c.relrowsecurity), 0,
          'every messages partition has RLS enabled');
SELECT is((SELECT count(*)::int FROM pg_inherits i
           WHERE i.inhparent = 'chats.messages'::regclass
             AND has_table_privilege('authenticated', i.inhrelid, 'SELECT')), 0,
          'messages partitions are not directly granted to API roles');

-- ===========================================================================
-- Regression tests of the security audit fixes
-- ===========================================================================

-- A partition created outside the install scripts is closed right away.
CREATE TABLE chats.messages_ptest PARTITION OF chats.messages
    FOR VALUES FROM ('2099-01-01') TO ('2099-01-08');
SELECT is((SELECT relrowsecurity FROM pg_class WHERE oid = 'chats.messages_ptest'::regclass), true,
          'a partition created by hand gets RLS immediately');
SELECT is(has_table_privilege('anon', 'chats.messages_ptest', 'SELECT'), false,
          'a partition created by hand is not granted to anon');
SELECT is((SELECT command FROM cron.job WHERE jobname = 'partman-run-maintenance'), 'CALL partman.run_maintenance_proc()',
          'the maintenance cron job runs the procedure alone (no shared transaction block)');
SELECT is((SELECT count(*)::int FROM cron.job WHERE jobname = 'chats-messages-partitions-rls'), 1,
          'the partitions RLS fix-up has its own cron job');

-- Media cleanup queue: only the deleted message's own room attachments.
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
INSERT INTO chats.messages ("roomId", "authorId", type, source, name, size)
SELECT (SELECT v FROM ids WHERE k = 'direct_ab'), auth.uid(), 'file', s, 'evil', 1
FROM unnest(ARRAY[
    'http://127.0.0.1:54321/storage/v1/object/authenticated/chats_assets/' || (SELECT v FROM ids WHERE k = 'group_abc') || '/other-room.pdf',
    'http://127.0.0.1:54321/storage/v1/object/authenticated/chats_user_avatar/fb000000-0000-0000-0000-000000000002/avatar.png',
    'x/object/authenticated/other_bucket/private/report.pdf',
    'http://127.0.0.1:54321/storage/v1/object/authenticated/chats_assets/'
]) AS s;
DELETE FROM chats.messages WHERE name = 'evil';
SELECT pg_temp.logout();
SELECT is((SELECT count(*)::int FROM chats.media_pending_deletion
           WHERE path LIKE '%other-room.pdf' OR "bucketId" <> 'chats_assets' OR path = ''), 0,
          'a message source cannot queue another room''s, another bucket''s or a malformed object');

-- Rooms and memberships: structural columns are not writable.
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
SELECT throws_ok(format($$UPDATE chats.rooms SET type = 'group' WHERE id = %L$$, (SELECT v FROM ids WHERE k = 'direct_ab')),
                 '42501', NULL, 'a room''s type cannot be changed');
SELECT throws_ok(format($$UPDATE chats.room_members SET "userId" = 'fc000000-0000-0000-0000-000000000003' WHERE "roomId" = %L AND "userId" = 'fb000000-0000-0000-0000-000000000002'$$,
                        (SELECT v FROM ids WHERE k = 'direct_ab')),
                 '42501', NULL, 'a membership cannot be moved to another user');
SELECT throws_ok(format($$UPDATE chats.room_members SET "roomId" = %L WHERE "roomId" = %L AND "userId" = auth.uid()$$,
                        (SELECT v FROM ids WHERE k = 'direct_ab'), (SELECT v FROM ids WHERE k = 'group_abc')),
                 '42501', NULL, 'a membership cannot be moved to another room');
UPDATE chats.room_members SET role = 'admin' WHERE "roomId" = (SELECT v FROM ids WHERE k = 'direct_ab') AND "userId" = auth.uid();
SELECT pg_temp.logout();
SELECT is((SELECT role FROM chats.room_members WHERE "roomId" = (SELECT v FROM ids WHERE k = 'direct_ab')
           AND "userId" = 'fa000000-0000-0000-0000-000000000001'), NULL, 'direct room members cannot promote themselves');
SELECT pg_temp.login('fb000000-0000-0000-0000-000000000002');
SELECT throws_ok($$UPDATE chats.users SET role = 'admin' WHERE id = auth.uid()$$, '42501', NULL, 'users cannot set their own global role');

-- Messages: unique ids, server-owned columns and time.
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
INSERT INTO chats.messages (id, "roomId", "authorId", type, text, pinned, reactions)
VALUES ('f0000000-0000-0000-0000-000000000002', (SELECT v FROM ids WHERE k = 'group_abc'), auth.uid(), 'text', 'original', true, '{"x":["fb000000-0000-0000-0000-000000000002"]}');
SELECT throws_ok(format($$INSERT INTO chats.messages (id, "roomId", "authorId", type, text, "createdAt")
                         VALUES ('f0000000-0000-0000-0000-000000000002', %L, auth.uid(), 'text', 'decoy', now() - interval '5 minutes')$$,
                        (SELECT v FROM ids WHERE k = 'direct_ab')),
                 '23505', NULL, 'a message id cannot be reused');
SELECT throws_ok(format($$INSERT INTO chats.messages ("roomId", "authorId", type, text, "createdAt")
                         VALUES (%L, auth.uid(), 'text', 'future', now() + interval '6 weeks')$$,
                        (SELECT v FROM ids WHERE k = 'group_abc')),
                 '22008', NULL, 'a far-future createdAt is rejected');
UPDATE chats.messages SET pinned = true, status = 'seen', reactions = '{"y":["fc000000-0000-0000-0000-000000000003"]}',
                          "createdAt" = now() + interval '20 weeks', text = 'edited'
WHERE id = 'f0000000-0000-0000-0000-000000000002';
SELECT pg_temp.logout();
SELECT is((SELECT row(pinned, status, reactions, text)::text FROM chats.messages WHERE id = 'f0000000-0000-0000-0000-000000000002'),
          row(NULL::boolean, 'sent'::text, NULL::jsonb, 'edited'::text)::text,
          'authors edit the content only: pin, status, reactions are server-owned');
SELECT ok((SELECT "createdAt" < now() + interval '1 minute' AND "updatedAt" IS NOT NULL FROM chats.messages WHERE id = 'f0000000-0000-0000-0000-000000000002'),
          'createdAt cannot be moved and edits always set updatedAt');

-- Forward origin is attested by the database.
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
SELECT throws_ok(format($$INSERT INTO chats.messages ("roomId", "authorId", type, text, metadata)
                         VALUES (%L, auth.uid(), 'text', 'fake', '{"forwardedFrom":{"authorId":"fb000000-0000-0000-0000-000000000002"}}')$$,
                        (SELECT v FROM ids WHERE k = 'direct_ab')),
                 '22023', NULL, 'a forward origin cannot be written by the client');
INSERT INTO chats.messages ("roomId", "authorId", type, text, metadata)
VALUES ((SELECT v FROM ids WHERE k = 'direct_ab'), auth.uid(), 'text', 'forwarded',
        jsonb_build_object('forwardedFrom', jsonb_build_object('sourceRoomId', (SELECT v FROM ids WHERE k = 'group_abc'),
                                                               'sourceMessageId', 'f0000000-0000-0000-0000-000000000002')));
SELECT is((SELECT metadata -> 'forwardedFrom' ->> 'authorId' FROM chats.messages WHERE text = 'forwarded'),
          'fa000000-0000-0000-0000-000000000001', 'a forward records the real author of its source');
SELECT pg_temp.login('fd000000-0000-0000-0000-000000000004');
INSERT INTO ids SELECT 'direct_ad', chats.create_room('direct', ARRAY['fa000000-0000-0000-0000-000000000001']::uuid[]);
SELECT throws_ok(format($$INSERT INTO chats.messages ("roomId", "authorId", type, text, metadata)
                         VALUES (%L, auth.uid(), 'text', 'stolen', %L)$$,
                        (SELECT v FROM ids WHERE k = 'direct_ad'),
                        jsonb_build_object('forwardedFrom', jsonb_build_object('sourceRoomId', (SELECT v FROM ids WHERE k = 'direct_ab'),
                                                                               'sourceMessageId', 'f0000000-0000-0000-0000-000000000002'))),
                 'P0002', NULL, 'only readable messages can be forwarded');
SELECT pg_temp.logout();

-- Storage: an attachment is overwritten by its uploader, deleted by its
-- uploader or a group admin. Supabase blocks direct deletes from storage
-- tables unless this is set (the Storage API sets it); RLS still applies.
SELECT set_config('storage.allow_delete_query', 'true', true);
INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES
    ('chats_assets', (SELECT v FROM ids WHERE k = 'group_abc') || '/carol.png', 'fc000000-0000-0000-0000-000000000003');
SELECT pg_temp.login('fd000000-0000-0000-0000-000000000004');
UPDATE storage.objects SET owner_id = auth.uid()::text WHERE name LIKE '%/carol.png';
DELETE FROM storage.objects WHERE name LIKE '%/carol.png';
SELECT pg_temp.logout();
SELECT is((SELECT owner_id FROM storage.objects WHERE name LIKE '%/carol.png'), 'fc000000-0000-0000-0000-000000000003',
          'members cannot overwrite or delete someone else''s attachment');
SELECT pg_temp.login('fa000000-0000-0000-0000-000000000001');
DELETE FROM storage.objects WHERE name LIKE '%/carol.png';
SELECT pg_temp.logout();
SELECT is((SELECT count(*)::int FROM storage.objects WHERE name LIKE '%/carol.png'), 0, 'group admins can delete attachments');

-- Realtime: who may send where, and per-user room changes.
SELECT pg_temp.login('fb000000-0000-0000-0000-000000000002');
SELECT is(chats.is_chat_typing_topic('chats:room:' || (SELECT v FROM ids WHERE k = 'group_abc') || ':typing'), true,
          'members may send on the typing channel');
SELECT is(chats.is_chat_typing_topic('chats:room:' || (SELECT v FROM ids WHERE k = 'group_abc')), false,
          'nobody may send on the message channel');
SELECT is(chats.is_chat_member_topic('chats:room:' || (SELECT v FROM ids WHERE k = 'group_abc') || ':typing'), true,
          'members may receive the typing channel');
SELECT is(chats.is_own_user_topic('chats:user:fb000000-0000-0000-0000-000000000002'), true, 'users receive their own user channel');
SELECT is(chats.is_own_user_topic('chats:user:fa000000-0000-0000-0000-000000000001'), false, 'users cannot receive someone else''s user channel');
SELECT is(chats.is_presence_topic('online-user-fa000000-0000-0000-0000-000000000001'), true, 'signed-in users may watch online status');
SELECT is(chats.is_own_presence_topic('online-user-fa000000-0000-0000-0000-000000000001'), false, 'users cannot publish someone else''s online status');
SELECT pg_temp.logout();
SELECT ok(EXISTS (SELECT 1 FROM realtime.messages WHERE topic = 'chats:user:fd000000-0000-0000-0000-000000000004'
                  AND event = 'room_change' AND payload ->> 'roomId' = (SELECT v FROM ids WHERE k = 'direct_ad')::text),
          'members are told about room changes on their own user channel');
SELECT is((SELECT count(*)::int FROM pg_publication_tables WHERE pubname = 'supabase_realtime'
           AND schemaname = 'chats' AND tablename IN ('rooms', 'room_members')), 0,
          'rooms and memberships are not published to Postgres Changes');

SELECT * FROM finish();
ROLLBACK;
