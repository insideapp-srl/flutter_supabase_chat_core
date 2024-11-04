DROP VIEW IF EXISTS chats.rooms_l;
create view chats.rooms_l as
select
    r.id,
    r."imageUrl",
    r.metadata,
    case
        when r.type = 'direct' and auth.uid() is not null then
            (select coalesce(u."firstName", '') || ' ' || coalesce(u."lastName", '')
             from chats.users u
             where u.id = any(r."userIds") and u.id <> auth.uid()
             limit 1)
        else
            r.name
        end as name,
    r.type,
    r."userIds",
    r."lastMessages",
    r."userRoles",
    r."createdAt",
    r."updatedAt"
from chats.rooms r;