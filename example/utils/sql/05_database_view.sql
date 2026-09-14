DROP VIEW IF EXISTS chats.messages_l;
DROP VIEW IF EXISTS chats.rooms_l;

-- Room membership lives in chats.room_members (not a chats.rooms."userIds"
-- uuid[]/"userRoles" jsonb pair) -- each embedded user object gets its
-- room-specific `role` folded in directly, so callers don't need a
-- separate userRoles lookup.
create or replace view chats.rooms_l
    with (security_invoker='on') as
select r.id,
       r."imageUrl",
       r.metadata,
       case
           when r.type = 'direct' and auth.uid() is not null then
               (select coalesce(u."firstName", '') || ' ' || coalesce(u."lastName", '')
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
       (select jsonb_agg(to_jsonb(u) || jsonb_build_object('role', rm.role))
        from chats.room_members rm
        join chats.users u on u.id = rm."userId"
        where rm."roomId" = r.id) as users
from chats.rooms r;


-- No author/room joins: flutter_chat_core's v2 Message model only carries
-- authorId (not an embedded author) and has no roomId field at all, so this
-- view is now a straight passthrough of chats.messages under RLS.
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
