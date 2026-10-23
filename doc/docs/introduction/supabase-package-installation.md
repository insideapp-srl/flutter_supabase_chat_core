---
id: supabase-package-installation
title: Package installation
---

This package depends on [supabase_flutter](https://pub.dev/packages/supabase_flutter): follow its [instructions](https://supabase.com/docs/reference/dart/introduction) to add Supabase to your app.

Requirements: `Dart >=3.9.0` and `Flutter >=3.35.0`.

```yaml
dependencies:
  flutter_supabase_chat_core: ^2.0.0-rc.3
  supabase_flutter: ^2.17.2
  uuid: ^4.5.1

  # Optional, for the ready-made UI:
  flutter_chat_ui: ^2.11.1
  flyer_chat_text_message: ^2.6.0
  flyer_chat_image_message: ^2.3.0
  flyer_chat_file_message: ^2.4.0
```

Check the current version on [pub.dev](https://pub.dev/packages/flutter_supabase_chat_core/install).

Since 2.x the package builds on [`flutter_chat_core`](https://pub.dev/packages/flutter_chat_core) (not `flutter_chat_types`): messages are `flutter_chat_core` `Message`s, and rooms and users are the package's own `ChatRoom` and `ChatUser`.

`flutter_chat_ui` 2.x ships no renderer for images, files or audio (only a minimal text fallback): add one `flyer_chat_*_message` package per message type you render, or write your own builder (the example app has its own voice message bubble).

:::caution
`flutter_chat_ui` 2.12.0 moved its `Composer` to the experimental `material_ui` package, which crashes inside a standard `Scaffold` ("No Material widget found"). The example app pins `flutter_chat_ui: '>=2.11.1 <2.12.0'`. For the same reason, since `flutter_chat_core` 2.9.1 `ChatTheme.fromThemeData` takes a `material_ui` theme: build the `ChatTheme` field by field, as `example/lib/src/theme/app_theme.dart` does.
:::

Initialize Supabase before using the package: `SupabaseChatCore.instance` is bound to `Supabase.instance.client`.

```dart
await Supabase.initialize(
  url: 'https://<project-ref>.supabase.co',
  publishableKey: '<anon-or-publishable-key>',
);
```

Upgrading an existing 1.x project? See [MIGRATION.md](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/MIGRATION.md), including the required database migration.
