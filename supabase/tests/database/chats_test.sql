-- pgTAP behaviour tests for the chat schema (example/utils/sql).
-- Run against the local stack after tool/local_db.sh:
--   supabase test db
-- Everything runs in one transaction that is rolled back at the end.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = extensions, public;

SELECT plan(67);

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

SELECT * FROM finish();
ROLLBACK;
