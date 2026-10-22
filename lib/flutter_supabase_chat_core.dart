/// Supabase backend for chat apps built on `flutter_chat_core` /
/// `flutter_chat_ui`: rooms, members, messages, attachments, read receipts,
/// reactions, typing indicators and online status, over Postgres + RLS and
/// Supabase Realtime.
library;

export 'src/class/chat_forward_origin.dart';
export 'src/class/chat_room.dart';
export 'src/class/chat_room_change.dart';
export 'src/class/chat_room_role.dart';
export 'src/class/chat_room_type.dart';
export 'src/class/chat_user.dart';
export 'src/class/supabase_chat_controller.dart';
export 'src/class/supabase_chat_core.dart';
export 'src/class/supabase_chat_core_config.dart';
export 'src/class/supabase_chat_core_exception.dart';
export 'src/class/supabase_chat_rooms_controller.dart';
export 'src/class/upload_asset_result.dart';
export 'src/class/user_online_status.dart';
export 'src/util.dart';
export 'src/widgets/user_online_status.dart';
export 'src/widgets/user_status_observer.dart';
