---
id: supabase-project-configuration
title: Supabase project preparation
---

### Create a Supabase project

1. Install Supabase CLI: [Official documentation](https://supabase.com/docs/guides/cli/getting-started)
2. Login with Supabase: `supabase login`
3. Install [`jq`](https://jqlang.org/download/) (Linux/macOS only; not needed on Windows)
4. Run the project creation script from `example/utils`:

#### Linux/macOS

```bash
cd example/utils
./supabase_prepare.sh
```

#### Windows

```powershell
cd example\utils
.\supabase_prepare.ps1
```

It creates the Supabase project (prompting for a name, organization ID and region), generates a database password for you (Supabase never shows it again after creation), writes `example/lib/supabase_options_for_test.dart` and `example/lib/main_test.dart` (both gitignored — `main.dart`/`supabase_options.dart` stay untouched), and offers to run the database preparation script (below) right away. Run the app with `flutter run -t lib/main_test.dart`.

All the references it collects — project ref, URL, anon/service_role keys, database host/port/user/password — are written to `example/utils/project-secrets.local.json`.

:::danger
`project-secrets.local.json` contains secrets. It's already gitignored — never commit it.
:::

<details>
<summary>Prefer the manual steps?</summary>

1. `supabase projects create demo-chat` (choose your organization, region, and a secure database password — save it, it won't be shown again)
2. `supabase projects list` to get the project's `REFERENCE ID`
3. `supabase projects api-keys --project-ref <reference_id>` to get the `anon` key
4. Edit `example/lib/supabase_options_for_test.dart` (create it if missing, see `example/lib/supabase_options.dart` for the shape), filling in your project's URL (`https://<reference_id>.supabase.co`) and anon key

</details>

#### Prepare Supabase project

Inside the example project (`example/utils`) there is a script, running the latter will automatically configure the Supabase project, creating tables, security rules, buckets and everything that is necessary for the example project to function. It's also idempotent and self-detecting — the same script bootstraps a fresh project or migrates an existing 1.x database, see [MIGRATION.md](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/MIGRATION.md).

:::info
Since 2.x, `chats.messages` is managed by [pg_partman](https://github.com/pgpartman/pg_partman) for partitioning, with maintenance scheduled via `pg_cron`. Both extensions ship enabled by default on Supabase's self-hosted Postgres image — on Supabase Cloud, enable them first from **Database > Extensions** in your project dashboard if they aren't already.
:::

In order to run the script you need to be aware of the following information about your Supabase project:

- `host` : Project host
- `port` : Database port
- `database` : Database name
- `user` : Database user
- `password` : Database password

This information, with the exception of the password which is provided only during the creation of the database (if necessary, you can use the password reset function of your database to obtain it), can be found very easily from the Dashboard of your Supabase project:

![Supabase dashboard database info](/img/supabase-project-credential.png "Database info")

#### Running prepare script

Below are the commands for running the scripts (During execution you will be asked for the password for your database user):

>   Required `psql` installed -> [Official documentation](https://www.postgresql.org/download/)

#### Linux

```bash
cd ./example/utils/
./prepare.sh -h "your-postgres-host" -p your-postgres-port -d "your-postgres-database-name" -U "your-postgres-user"
```

#### Windows

```powershell
cd .\example\utils\
.\prepare.ps1 -hostname "your-postgres-host" -port your-postgres-port -database "your-postgres-database-name" -user "your-postgres-user"
```


after running the database preparation script. you need to change the database schema exposure setting by adding the `chats` schema (from the supabase dashboard):

![Supabase dashboard schema exposure setting](/img/supabase-schema-exposure-setting.png "Schema exposure setting")

Optional (**Only for test**): Disable email verification and save the configuration (To speed up testing and allow user registration in just one click, it is advisable to disable mailbox verification):

![Supabase dashboard disable email verification](/img/supabase-disable-confirm-email.png "Disable email verification")

Read our [documentation](https://flutter-supabase-chat-core.insideapp.it) or see the [example](https://github.com/insideapp-srl/flutter_supabase_chat_core/tree/main/example) project. To run the example project you need to have your own [Supabase](https://supabase.com/dashboard/projects) project — `supabase_prepare.sh`/`.ps1` above sets this up for you; if you'd rather do it by hand, follow [Add Supabase to your Flutter app](https://supabase.com/docs/reference/dart/initializing) and fill in `example/lib/supabase_options_for_test.dart` (gitignored — see `supabase_options.dart` for the shape, and don't edit that tracked file directly) plus a `main_test.dart` importing it 😉

After all of this is done you will need to register a couple of users and the example app will automatically suggest email and password on the register screen, default password is `Qawsed1-`. To set up [Supabase Security Rules](https://supabase.com/docs/guides/database/postgres/row-level-security) so users can see only the data they should see, continue with our [documentation](https://flutter-supabase-chat-core.insideapp.it/).
