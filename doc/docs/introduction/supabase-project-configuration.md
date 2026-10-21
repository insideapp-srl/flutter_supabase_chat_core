---
id: supabase-project-configuration
title: Supabase project preparation
---

The database is set up by the SQL scripts in [`example/utils/sql`](https://github.com/insideapp-srl/flutter_supabase_chat_core/tree/main/example/utils/sql), applied in this order:

| Script | Content |
|--------|---------|
| `01_database_schema.sql` | Schema `chats`, tables, weekly partitions of `chats.messages`, indexes, `pg_cron` maintenance job. Also migrates a 1.x database. |
| `02_database_trigger.sql` | [Triggers](../guides/supabse-trigges.md): profile creation, last message snapshot, `sent` status, media cleanup queue, empty room deletion, Realtime broadcast of message changes. |
| `03_database_policy.sql` | Access helpers, RPCs and [RLS policies](../guides/supabase-security-rls.md) (tables and `realtime.messages`). |
| `04_storage.sql` | Buckets `chats_assets` and `chats_user_avatar` and their policies. |
| `05_database_view.sql` | [Views](../guides/supabse-views.md) `chats.rooms_l` and `chats.messages_l`. |
| `99_database_schema_permission.sql` | Final grants. |
| `06_cleanup_media_schedule.sql` | Optional: schedules the `cleanup-media` Edge Function (see [Usage](../guides/supabase-usage.md#media-cleanup)). |

Every script is idempotent, so re-running them is safe. `01_database_schema.sql` detects the shape of the database: it creates the 2.x schema on a fresh database, migrates a 1.x one (see [MIGRATION.md](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/MIGRATION.md)) and does nothing on an up-to-date one.

:::info Requirements
* The `pg_partman` and `pg_cron` extensions must be available: the script creates them (`pg_partman` in its own `partman` schema).
* Realtime must support **Broadcast from Database** (Supabase cloud, or self-hosted `supabase/realtime` >= v2.33): message changes are sent by a database trigger.
:::

## Option A: Supabase CLI

1. Install the [Supabase CLI](https://supabase.com/docs/guides/cli/getting-started) and log in with `supabase login` (the script opens the login flow if needed).
2. Linux/macOS only: install [`jq`](https://jqlang.org/download/).
3. Run the script from `example/utils`:

```bash
cd example/utils
./supabase_prepare.sh
```

```powershell
cd example\utils
.\supabase_prepare.ps1
```

It asks whether to create a new project (organization and region picked from a list with the arrow keys, database password generated for you) or to use an existing one (it then asks for its database password, which Supabase only shows at creation time). Then it:

* fetches the project's API keys;
* writes `example/lib/supabase_options_for_test.dart` and `example/lib/main_test.dart` (both gitignored; the tracked `main.dart`/`supabase_options.dart` stay untouched), so you can run the example with `flutter run -t lib/main_test.dart`;
* writes `example/utils/project-secrets.local.json` with the project ref, URL, keys and database credentials;
* offers to apply scripts `01`…`05` and `99` with `supabase link` + `supabase db query --linked`. This goes through Supavisor's IPv4-compatible pooler, so it also works on networks without IPv6, where a direct `db.<ref>.supabase.co` connection hangs. If you skip this step, it prints the commands to run later.

:::danger
`project-secrets.local.json` contains secrets. It's gitignored: never commit it.
:::

<details>
<summary>Manual project creation</summary>

1. `supabase projects create demo-chat` (choose your organization, region, and a secure database password — save it, it won't be shown again)
2. `supabase projects list` to get the project's `REFERENCE ID`
3. `supabase projects api-keys --project-ref <reference_id>` to get the `anon`/publishable key

</details>

## Option B: psql

`prepare.sh`/`prepare.ps1` apply scripts `01`…`05` and `99` with [`psql`](https://www.postgresql.org/download/). They ask for the database password once (or read `PGPASSWORD`), stop at the first failing script, and can be run from any directory.

```bash
./example/utils/prepare.sh -h <host> -p <port> -d <database> -U <user>
```

```powershell
.\example\utils\prepare.ps1 -hostname <host> -port <port> -database <database> -user <user>
```

The connection parameters are in the dashboard of your project:

![Supabase dashboard database info](/img/supabase-project-credential.png "Database info")

Neither script applies the optional `06_cleanup_media_schedule.sql`: it needs the Edge Function deployed and two Vault secrets first (see [Usage](../guides/supabase-usage.md#media-cleanup)).

## Expose the `chats` schema

After the scripts, add `chats` to the schemas exposed by the Data API (Dashboard → Project Settings → Data API):

![Supabase dashboard schema exposure setting](/img/supabase-schema-exposure-setting.png "Schema exposure setting")

Optional, **for testing only**: disable email confirmation to sign up in one click.

![Supabase dashboard disable email verification](/img/supabase-disable-confirm-email.png "Disable email verification")

## Run the example

```bash
cd example
flutter run -t lib/main_test.dart   # after supabase_prepare.sh/.ps1
# or, with any project:
flutter run --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
            --dart-define=SUPABASE_ANON_KEY=<anon-or-publishable-key>
```

Create an account from the sign-in page ("Fill in a demo account" generates a name, an email and the password `Demo-password-1`). The profile is created by the `chats.handle_new_user` trigger from the sign-up metadata. To try it against a local stack with demo data, see [Testing](../guides/testing.md).
