import 'package:flutter_chat_types/flutter_chat_types.dart' as types;

extension UserEx on types.User {
  String getUserName() => firstName != null || lastName != null
      ? '${firstName ?? ''} ${lastName ?? ''}'.trim()
      : id;
}
