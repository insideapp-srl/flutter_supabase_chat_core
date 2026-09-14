import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

extension UserEx on ChatUser {
  String getUserName() => fullName.isEmpty ? id : fullName;
}
