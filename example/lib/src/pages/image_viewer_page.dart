import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';

/// Full-screen, zoomable image.
class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({super.key, required this.message});

  final core.ImageMessage message;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
    ),
    body: Center(
      child: InteractiveViewer(
        maxScale: 5,
        child: Hero(
          tag: message.id,
          child: Image.network(
            message.source,
            headers: SupabaseChatCore.instance.httpSupabaseHeaders,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : const CircularProgressIndicator(color: Colors.white),
            errorBuilder: (_, _, _) => const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 64,
            ),
          ),
        ),
      ),
    ),
  );
}
