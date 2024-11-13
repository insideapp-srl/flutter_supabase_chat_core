---
id: supabase-views
title: Database Views
---

## Rooms view

This is a view of `rooms` table, this view allows you to obtain the name of the sender of the message dynamically in direct rooms, based on the logged-in user the name of the correspondent is displayed.

```sql
DROP VIEW IF EXISTS chats.rooms_l;
create view chats.rooms_l
    WITH (security_invoker='on') as
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
```
