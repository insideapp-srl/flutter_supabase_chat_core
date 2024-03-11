class SupabaseOptions {
  final String url;
  final String anonKey;

  SupabaseOptions({
    required this.url,
    required this.anonKey,
  });
}

final SupabaseOptions supabaseOptions = SupabaseOptions(
  url: 'https://{{your_project_reference_id}}.supabase.co',
  anonKey: '{{supabase_anon_key}}',
);
