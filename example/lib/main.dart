import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/app.dart';
import 'supabase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: supabaseOptions.url,
    publishableKey: supabaseOptions.anonKey,
  );
  runApp(const ChatExampleApp());
}
