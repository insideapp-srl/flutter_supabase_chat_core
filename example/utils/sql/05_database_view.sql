DROP VIEW IF EXISTS chats.messages_l;
DROP VIEW IF EXISTS chats.rooms_l;

create or replace view chats.rooms_l
    with (security_invoker='on') as
select r.id,
       r."imageUrl",
       r.metadata,
       case
           when r.type = 'direct' and auth.uid() is not null then
               (select coalesce(u."firstName", '') || ' ' || coalesce(u."lastName", '')
                from chats.users u
                where u.id = any (r."userIds")
                  and u.id <> auth.uid()
                limit 1)
           else
               r.name
           end                          as name,
       r.type,
       r."userIds",
       r."lastMessages",
       r."userRoles",
       r."createdAt",
       r."updatedAt",
       (select jsonb_agg(to_jsonb(u))
        from chats.users u
        where u.id = any (r."userIds")) as users
from chats.rooms r;


create or replace view chats.messages_l
    with (security_invoker='on') as
select m.id,
       m."createdAt",
       m.metadata,
       m.duration,
       m."mimeType",
       m.name,
       m."remoteId",
       m."repliedMessage",
       m."roomId",
       m."showStatus",
       m.size,
       m.status,
       m.type,
       m."updatedAt",
       m.uri,
       m."waveForm",
       m."isLoading",
       m.height,
       m.width,
       m."previewData",
       m."authorId",
       m.text,
       to_jsonb(u) as author,
       to_jsonb(r) as room
from chats.messages m
         left join chats.users u on u.id = m."authorId"
         left join chats.rooms_l r on r.id = m."roomId";
