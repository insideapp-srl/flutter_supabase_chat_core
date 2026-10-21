---
id: testing
title: Testing and development
---

The repository has three test suites and a few scripts to run them against a local Supabase stack, started with the [Supabase CLI](https://supabase.com/docs/guides/cli/getting-started) (`supabase/config.toml` exposes the `chats` schema). The scripts are Bash and need `psql`, `curl` and Docker.

## Unit tests

Models, date parsing and the mapping between `chats.messages` rows and `flutter_chat_core` messages. No backend needed:

```bash
flutter test test/unit
```

## Integration tests

`test/integration` drives the real package against the local stack: users, rooms and scoping hooks, real-time delivery and reconciliation, read receipts, pagination, edits/reactions/deletions, voice messages, attachments' access rules, pinned and muted rooms, the typing indicator, `roomsChanges()`, `SupabaseChatRoomsController` and online status. Every test user gets its own `SupabaseClient` and `SupabaseChatCore`.

```bash
supabase start                # once
tool/test_integration.sh      # resets the DB, applies the SQL, runs the tests
tool/test_integration.sh --no-reset   # keeps the current database
```

The script exports `CHAT_TEST_SUPABASE_URL`, `CHAT_TEST_ANON_KEY` and `CHAT_TEST_SERVICE_ROLE_KEY` from `supabase status`; without them the integration tests are skipped. Other arguments are forwarded to `flutter test`.

## Database tests (pgTAP)

`supabase/tests/database/chats_test.sql` checks the RLS policies, RPCs, triggers, views, storage and Realtime helpers and the partitions' RLS, in a transaction rolled back at the end:

```bash
tool/local_db.sh
supabase test db
```

## Scripts

| Script | Purpose |
|--------|---------|
| `tool/local_db.sh` | Resets the local database, applies `example/utils/sql` exactly like end users do, reloads PostgREST's schema cache and restarts the Realtime container. `--no-reset` applies the scripts on top of the current database, to check they are idempotent |
| `tool/test_integration.sh` | `tool/local_db.sh` + integration tests |
| `tool/v1_fixture.sh` | Rebuilds the local database in the 1.x shape (SQL scripts from the `main` branch, or `V1_REF`) with sample data. Follow it with `tool/local_db.sh --no-reset` to exercise the 1.x → 2.x migration |
| `tool/test_storage_migration.sh` | Builds a 1.x database with attachments in the old room folders, migrates it and runs `example/utils/migrate_storage_uuids.sh` (dry run, resume after a stop, URLs, cleanup of the map). `--ps` runs the PowerShell variant |
| `tool/seed_demo.sh` | Seeds demo users and conversations (direct and group rooms, replies, reactions, a pinned message, a muted and pinned group, unread messages, a voice message) |

## Trying the example locally

```bash
supabase start
tool/local_db.sh && tool/seed_demo.sh
cd example
flutter run --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
            --dart-define=SUPABASE_ANON_KEY=<anon key from `supabase status`>
```

Sign in as `alice@demo.dev` with password `Demo-password-1` (also `bob@demo.dev`, `carol@demo.dev`, `dave@demo.dev`, `erin@demo.dev`).
