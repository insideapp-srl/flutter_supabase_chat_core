DROP VIEW IF EXISTS chats.messages_l;
DROP VIEW IF EXISTS chats.rooms_l;

-- Rooms the caller is a member of (RLS, security_invoker), with:
--   - "users": every member, each with its room-specific `role` folded in,
--     so callers don't need a separate room_members lookup;
--   - "name": for direct rooms, the other member's full name;
--   - "lastReadAt": when the caller last marked the room as read;
--   - "pinnedAt"/"mutedUntil": the caller's own pin/mute preferences;
--   - "unreadCount": messages from other members newer than that, capped at
--     100 so a long-unread room never costs a full scan (show "99+").
create or replace view chats.rooms_l
    with (security_invoker='on') as
select r.id,
       r."imageUrl",
       r.metadata,
       case
           when r.type = 'direct' and auth.uid() is not null then
               (select nullif(trim(coalesce(u."firstName", '') || ' ' || coalesce(u."lastName", '')), '')
                from chats.room_members rm
                join chats.users u on u.id = rm."userId"
                where rm."roomId" = r.id
                  and rm."userId" <> auth.uid()
                limit 1)
           else
               r.name
           end                          as name,
       r.type,
       r."lastMessages",
       r."createdAt",
       r."updatedAt",
       (select jsonb_agg(to_jsonb(u) || jsonb_build_object('role', rm.role) order by rm."createdAt")
        from chats.room_members rm
        join chats.users u on u.id = rm."userId"
        where rm."roomId" = r.id) as users,
       me."lastReadAt",
       me."pinnedAt",
       me."mutedUntil",
       (select count(*)
        from (select 1
              from chats.messages m
              where m."roomId" = r.id
                and m."authorId" <> auth.uid()
                and m."createdAt" > coalesce(me."lastReadAt", '-infinity'::timestamptz)
              limit 100) unread)::int as "unreadCount"
from chats.rooms r
left join chats.room_members me
       on me."roomId" = r.id and me."userId" = auth.uid();


-- No author/room joins: flutter_chat_core's v2 Message model only carries
-- authorId (not an embedded author) and has no roomId field at all, so this
-- view is a straight passthrough of chats.messages under RLS.
create or replace view chats.messages_l
    with (security_invoker='on') as
select m.id,
       m."createdAt",
       m.metadata,
       m.duration,
       m."mimeType",
       m.name,
       m."replyToMessageId",
       m."roomId",
       m.size,
       m.status,
       m.type,
       m."updatedAt",
       m.source,
       m.waveform,
       m.height,
       m.width,
       m."linkPreviewData",
       m."authorId",
       m.text,
       m.reactions,
       m.pinned
from chats.messages m;

GRANT SELECT ON chats.rooms_l TO authenticated, service_role;
GRANT SELECT ON chats.messages_l TO authenticated, service_role;
