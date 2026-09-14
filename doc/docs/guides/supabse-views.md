---
id: supabase-views
title: Database Views
---

## Rooms view

This is a view of `rooms` table, this view allows you to obtain the name of the sender of the message dynamically in direct rooms, based on the logged-in user the name of the correspondent is displayed, it is also included the list of uses member objects.

```sql
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
```


## Messages view

This is a view of the `messages` table. Since 2.x it's a straight passthrough of `chats.messages` under RLS: `flutter_chat_core`'s v2 `Message` model only carries `authorId` (a plain string), not an embedded author object, and has no room concept at all — so there's no `author`/`room` join to do anymore (contrast with `rooms_l` above, which still resolves participant users for the room list). Column names match `flutter_chat_core`'s v2 field names directly (`source`, `waveform`, `linkPreviewData`, `replyToMessageId`, ...).

```sql
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
```