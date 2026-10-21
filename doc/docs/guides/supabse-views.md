---
id: supabase-views
title: Database Views
---

The client reads rooms and messages through two views defined in `example/utils/sql/05_database_view.sql`. Both are `security_invoker`, so the RLS policies of the underlying tables apply to the caller.

## Rooms view

`chats.rooms_l` returns the rooms the caller is a member of, with everything a rooms list needs in one query:

* `users`: every member, each with its room-specific `role` folded in (ordered by join time);
* `name`: for direct rooms, the other member's full name;
* `lastReadAt`, `pinnedAt`, `mutedUntil`: the caller's own membership state;
* `unreadCount`: messages from other members newer than `lastReadAt`, capped at 100 so a long-unread room never costs a full scan (show "99+").

```sql
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
```

`ChatRoom.fromJson(row, currentUserId: uid)` builds a `ChatRoom` from a row; for direct rooms it also takes the avatar of the other member. `mutedUntil = 'infinity'` (muted for ever) becomes `ChatRoom.mutedForever`.

## Messages view

`chats.messages_l` is a straight passthrough of `chats.messages` under RLS: `flutter_chat_core`'s `Message` only carries `authorId` (not an embedded author) and has no room field, so there is nothing to join. Column names match `flutter_chat_core`'s field names (`source`, `waveform`, `linkPreviewData`, `replyToMessageId`, ...); `messageFromRow` converts a row to a `Message` (dates to epoch milliseconds, `duration` from the stored milliseconds to seconds).

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

Both views are granted `SELECT` to `authenticated` and `service_role`. To expose a narrower list of users (e.g. only the ones sharing a workspace with the caller), create your own view and point `SupabaseChatCoreConfig.usersViewName` at it.
