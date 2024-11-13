---
id: supabase-indexes
title: Database Indexes
---

## `chats.messages` indexes

These indexes are added to improve the performance of foreign keys in database tables:

```sql
CREATE INDEX ON "chats"."messages" USING btree ("authorId");
CREATE INDEX ON "chats"."messages" USING btree ("roomId");
```
