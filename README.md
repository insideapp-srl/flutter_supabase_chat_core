<br>

<p align="center">
  <a href="https://flyer.chat">
    <img src="https://flyer.chat/assets/logo-dark.svg" width="288px" alt="Flyer Chat logo" />
  </a>
</p>

<h1 align="center">Flutter Supabase Chat Core</h1>

<p align="center">
    This project is an implementation of the <a href="https://pub.dev/packages/flutter_chat_types">flutter_chat_types</a>, <a href="https://pub.dev/packages/flutter_chat_ui">flutter_chat_ui</a> packages based on a backend created with <a href="https://supabase.com/">Supabase</a>.
</p>

<br>

<p align="center">
  Actively maintained, community-driven Supabase BaaS for chat applications with an optional <a href="https://pub.dev/packages/flutter_chat_ui">chat UI</a>.
</p>

<br>

<p align="center">
  ⚠️⚠️ Recommended for small or PoC projects, might not be optimized for large amounts of data. I suggest to use this on a free plan, otherwise be extremely cautious. ⚠️⚠️
</p>

<br>

<p align="center">
  <a href="https://pub.dartlang.org/packages/flutter_supabase_chat_core">
    <img alt="Pub" src="https://img.shields.io/pub/v/flutter_supabase_chat_core" />
  </a>
  <a href="https://github.com/insideapp-srl/flutter_supabase_chat_core/actions?query=workflow%3Abuild">
    <img alt="Build Status" src="https://github.com/insideapp-srl/flutter_supabase_chat_core/workflows/build/badge.svg" />
  </a>
  <a href="https://www.codefactor.io/repository/github/insideapp-srl/flutter_supabase_chat_core">
    <img alt="CodeFactor" src="https://www.codefactor.io/repository/github/insideapp-srl/flutter_supabase_chat_core/badge" />
  </a>
</p>

<br>

<p align="center">
  <a href="https://flyer.chat">
    <img alt="Chat Image" src="https://user-images.githubusercontent.com/14123304/193468140-91942302-2332-4cb1-8504-61b8892d828b.jpg" />
  </a>
</p>

<br>

Flyer Chat is a platform for creating in-app chat experiences using Flutter or [React Native](https://github.com/flyerhq/react-native-supabase-chat-core). This repository contains Supabase BaaS implementation for Flutter. We are also working on our more advanced SaaS and self-hosted solutions.

* **Free, open-source and community-driven**. We offer no paid plugins and strive to create an easy-to-use, almost drop-in chat experience for any application. Contributions are more than welcome! Please read our [Contributing Guide](CONTRIBUTING.md).

* **Chat UI agnostic**. You can choose the chat UI you prefer. But if you don't have one, we provide our own free and open-source [Flutter Chat UI](https://pub.dev/packages/flutter_chat_ui), which can be used to create a working chat in minutes.

* **Easy to use**. Returns streams of data for messages, rooms and users. [Supabase Security Rules](https://supabase.com/docs/guides/database/postgres/row-level-security) control access to the data. Check our [documentation](https://flutter-supabase-chat-core.insideapp.it/guides/supabase-security) for the info.

## Getting Started

The example project that you find in the package repository allows you to have a cross-platform chat app in just a few minutes.

### Requirements

`Dart >=2.19.0` and `Flutter >=3.0.0`, [Supabase](https://supabase.com) project.

#### Prepare Supabase project

Inside the example project (`example/utils`) there is a script, running the latter will automatically configure the Supabase project, creating tables, security rules, buckets and everything that is necessary for the example project to function.

In order to run the script you need to be aware of the following information about your Supabase project:

- `host` : Project host
- `port` : Database port
- `database` : Database name
- `user` : Database user
- `password` : Database password

This information, with the exception of the password which is provided only during the creation of the database (if necessary, you can use the password reset function of your database to obtain it), can be found very easily from the Dashboard of your Supabase project:

![Supabase dashboard database info](doc/static/img/supabase_project_credential.png "Database info")

#### Running prepare script

Below are the commands for running the scripts (During execution you will be asked for the password for your database user):

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

![Supabase dashboard schema exposure setting](doc/static/img/supabase-schema-exposure-setting.png "Schema exposure setting")

Read our [documentation](https://flutter-supabase-chat-core.insideapp.it) or see the [example](https://github.com/insideapp-srl/flutter_supabase_chat_core/tree/main/example) project. To run the example project you need to have your own [Supabase](https://supabase.com/dashboard/projects) project and then follow [Add Supabase to your Flutter app](https://supabase.com/docs/reference/dart/initializing), override `example/lib/supabase_options.dart`, don't commit it though 😉

After all of this is done you will need to register a couple of users and the example app will automatically suggest email and password on the register screen, default password is `Qawsed1-`. To set up [Supabase Security Rules](https://supabase.com/docs/guides/database/postgres/row-level-security) so users can see only the data they should see, continue with our [documentation](https://flutter-supabase-chat-core.insideapp.it/).

## Contributing

Please read our [Contributing Guide](CONTRIBUTING.md) before submitting a pull request to the project.

## Code of Conduct

Flyer Chat has adopted the [Contributor Covenant](https://www.contributor-covenant.org) as its Code of Conduct, and we expect project participants to adhere to it. Please read [the full text](CODE_OF_CONDUCT.md) so that you can understand what actions will and will not be tolerated.

## License

Licensed under the [Apache License, Version 2.0](LICENSE)

## Example project progress

Below are the features implemented for each platform:

| Feature               | Web | Android | iOS | Windows | macOS |  Linux   |
|-----------------------|:-:|:-------:|:---:|:-------:|:-----:|:--------:|
| Signup                | ✅ |         |     |    ✅    |       |          |
| Signin                | ✅ |         |     |    ✅    |       |          |
| Rooms list screen     | ✅ |         |     |    ✅    |       |          |
| Create direct room    | ✅ |         |     |         |       |          |
| Create group room     |   |         |     |         |       |          |
| Create channel room   |   |         |     |         |       |          |
| Chat screen           | ✅ |         |     | ✅ |       |          |
| Search room           |   |         |     |         |       |          |
| Upload image          | ✅ |         |     | ✅ |       |          |
| Preview image message | ✅ |         |     | ✅ |       |          |
| Upload file           | ✅ |         |     |         |       |          |
| Download file         |   |         |     |         |       |          |

## RLS (Row level security)

The preparation script automatically configures the security rules on the database tables and storage buckets, below is a summary of the rules that are applied:

### Tables

#### Table `chats.users`

- `INSERT` : Nobody, this table is populate by trigger on auth.users. 
- `SELECT` : All users authenticated.
- `UPDATE` : Only the user himself.
- `DELETE` : Nobody.

#### Table `chats.rooms`

- `INSERT` : All users authenticated.
- `SELECT` : All users who are members of the chat room.
- `UPDATE` : All users who are members of the chat room.
- `DELETE` : All users who are members of the chat room.

#### Table `chats.messages`

- `INSERT` : All users who are members of the chat room.
- `SELECT` : All users who are members of the chat room.
- `UPDATE` : All users who are members of the chat room.
- `DELETE` : All users who are members of the chat room.

### Storage buckets

#### Bucket `chats_assets`

- `INSERT` : All users who are members of the chat room.
- `SELECT` : All users who are members of the chat room.
- `UPDATE` : All users who are members of the chat room.
- `DELETE` : All users who are members of the chat room.

#### Bucket `chats_user_avatar`

- `INSERT` : Only the user himself.
- `SELECT` : All users authenticated.
- `UPDATE` : Only the user himself.
- `DELETE` : Only the user himself.

## Activities to complete (Roadmap)

Below are some activities to complete to have a more complete and optimized project also for use cases in larger projects.

1. Check the correct functioning of the RLS security rules
2. Add the missing triggers
3. Optimization of the join of users who are part of a chat room. At the moment every time you want to get a chat room a SELECT is performed to get the users of the chat room. It does not perform as the chat rooms or users present in them grow.
4. Error handling
5. Chat room groups
6. Chat room channels
7. Sending audio messages
8. Improve documentation