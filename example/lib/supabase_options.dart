class SupabaseOptions {
  final String url;
  final String anonKey;

  const SupabaseOptions({required this.url, required this.anonKey});
}

/// Fill in your project's URL and anon/publishable key, or pass them at
/// build time without editing this file:
///
/// ```sh
/// flutter run --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
///             --dart-define=SUPABASE_ANON_KEY=<anon-or-publishable-key>
/// ```
const SupabaseOptions supabaseOptions = SupabaseOptions(
  url: String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://{{your_project_reference_id}}.supabase.co',
  ),
  anonKey: String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '{{supabase_anon_key}}',
  ),
);
