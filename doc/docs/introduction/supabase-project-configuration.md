---
id: supabase-project-configuration
title: Supabase project preparation
---

### Create a Supabase project

1. Install Supabase CLI: [Official documentation](https://supabase.com/docs/guides/cli/getting-started)
2. Open your bash
3. Login with Supabase:

```bash
supabase login
```

4. Create new project (For example `demo-chat`):

```bash
supabase projects create demo-chat
```

5. Select your organization
6. Select an region
7. Insert a secure password for new Postgres database (Save this in a secure location)
8. Obtain your `REFERENCE ID` (After command select your project, for example `demo-chat`):

```bash
supabase projects list
```

9. Obtain your `anon` key (After command select your project, for example `demo-chat`):

```bash
supabase projects api-keys
```
10. Edit `example project` file `example/lib/supabase_options.dart`, insert your project `{{your_project_reference_id}}` and `{{supabase_anon_key}}`

#### Prepare Supabase project

Inside the example project (`example/utils`) there is a script, running the latter will automatically configure the Supabase project, creating tables, security rules, buckets and everything that is necessary for the example project to function.

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

Read our [documentation](https://flutter-supabase-chat-core.insideapp.it) or see the [example](https://github.com/insideapp-srl/flutter_supabase_chat_core/tree/main/example) project. To run the example project you need to have your own [Supabase](https://supabase.com/dashboard/projects) project and then follow [Add Supabase to your Flutter app](https://supabase.com/docs/reference/dart/initializing), override `example/lib/supabase_options.dart`, don't commit it though 😉

After all of this is done you will need to register a couple of users and the example app will automatically suggest email and password on the register screen, default password is `Qawsed1-`. To set up [Supabase Security Rules](https://supabase.com/docs/guides/database/postgres/row-level-security) so users can see only the data they should see, continue with our [documentation](https://flutter-supabase-chat-core.insideapp.it/).
