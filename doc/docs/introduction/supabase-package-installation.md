---
id: supabase-package-installation
title: Installation supabase_flutter
---

This library depends on [supabase_flutter](https://pub.dev/packages/supabase_flutter). Follow the instructions there to configure the Supabase project and install [supabase_flutter](https://supabase.com/docs/reference/dart/introduction) plugin.

Add `flutter_supabase_chat_core` to your package's `pubspec.yaml` file. Check current version on [pub.dev](https://pub.dev/packages/flutter_supabase_chat_core/install).

Since 2.x this package builds on [`flutter_chat_core`](https://pub.dev/packages/flutter_chat_core) (not `flutter_chat_types`). If you also want the ready-made UI, add [`flutter_chat_ui`](https://pub.dev/packages/flutter_chat_ui) 2.x plus one `flyer_chat_*_message` package per message type you use (e.g. `flyer_chat_text_message`, `flyer_chat_image_message`, `flyer_chat_file_message`) — `flutter_chat_ui` 2.x ships no built-in renderer beyond a minimal text fallback.

Upgrading an existing 1.x project? See [MIGRATION.md](https://github.com/insideapp-srl/flutter_supabase_chat_core/blob/main/MIGRATION.md) for the full guide, including the required database migration.