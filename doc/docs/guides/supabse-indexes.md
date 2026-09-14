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

## `chats.messages` primary key

Since 2.x, `chats.messages` is a native `PARTITION BY RANGE ("createdAt")` table (see [pg_partman partitioning](#pg_partman-partitioning) below). Postgres requires the partition key to be part of every unique/primary key index, so the primary key is composite — `(id, "createdAt")` — instead of just `id`:

```sql
ALTER TABLE ONLY chats.messages ADD CONSTRAINT messages_pkey PRIMARY KEY (id, "createdAt");
```

Nothing else references `messages.id` via foreign key, so this doesn't affect any other table.

## `chats.rooms`/`chats.messages` ids are uuid (v7)

Since 2.x, `chats.rooms.id` and `chats.messages.id` are `uuid` (default `chats.uuid_generate_v7()`) instead of a `bigint` identity — `chats.users.id` is unaffected, it must keep matching `auth.users.id`. `uuid_generate_v7()` produces time-ordered UUIDs (like the old bigint identities), not fully random ones: a fully random primary key (`gen_random_uuid()`/UUIDv4) would fragment each partition's index on every insert, which especially matters for `chats.messages` given the partitioning above. Client code should generate message ids the same way — `const Uuid().v7()`, not `.v4()` — since `SupabaseChatController.sendMessage` sends that id to Supabase as-is (needed for its optimistic UI: the message appears locally immediately, and the id lets it recognize Realtime's echo of the same row instead of duplicating it).

## pg_partman partitioning

`chats.messages` is managed by [pg_partman](https://github.com/pgpartman/pg_partman): weekly partitions on `"createdAt"` (stored as epoch milliseconds — pg_partman is told this via `p_epoch => 'milliseconds'`), with no automatic retention (chat history is kept forever; this is purely for query/index/vacuum scalability as history grows). Upcoming partitions are pre-created by an hourly `pg_cron` job. Requires the `pg_partman` and `pg_cron` extensions, both available on Supabase's self-hosted Postgres image. See `example/utils/sql/01_database_schema.sql` and [MIGRATION.md](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/MIGRATION.md) for the full setup, including how an existing (non-partitioned) table is converted in place.
