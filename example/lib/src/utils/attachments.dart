import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;
import 'package:flutter_supabase_chat_core/flutter_supabase_chat_core.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import 'format.dart';

/// What the user wants to attach. [audio] is recorded from the composer's
/// microphone, not offered by [AttachmentPickerSheet].
enum AttachmentKind { camera, gallery, file, audio }

/// Bottom sheet offering the attachment kinds available on this platform.
class AttachmentPickerSheet extends StatelessWidget {
  const AttachmentPickerSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final options = [
      if (mobile)
        (AttachmentKind.camera, Icons.photo_camera_outlined, 'Camera', 0),
      (AttachmentKind.gallery, Icons.photo_outlined, 'Photo', 1),
      (AttachmentKind.file, Icons.insert_drive_file_outlined, 'File', 2),
    ];
    final scheme = Theme.of(context).colorScheme;
    final tints = [
      scheme.primaryContainer,
      scheme.tertiaryContainer,
      scheme.secondaryContainer,
      scheme.errorContainer,
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Wrap(
          alignment: WrapAlignment.spaceEvenly,
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final (kind, icon, label, tint) in options)
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => Navigator.pop(context, kind),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    spacing: 8,
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: tints[tint],
                        child: Icon(icon, size: 28),
                      ),
                      Text(label),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lets the user pick/record an attachment of [kind], uploads it to
/// [room]'s folder and returns the message to send (or `null` if
/// cancelled).
Future<core.Message?> pickAttachment(
  BuildContext context,
  AttachmentKind kind, {
  required ChatRoom room,
  required String authorId,
}) async {
  final chat = SupabaseChatCore.instance;
  switch (kind) {
    case AttachmentKind.camera:
    case AttachmentKind.gallery:
      final picked = await ImagePicker().pickImage(
        source: kind == AttachmentKind.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        imageQuality: 75,
        maxWidth: 1920,
      );
      if (picked == null) return null;
      final bytes = await picked.readAsBytes();
      final image = await decodeImageFromList(bytes);
      final upload = await chat.uploadAsset(room, picked.name, bytes);
      return core.Message.image(
        id: const Uuid().v7(),
        authorId: authorId,
        source: upload.url,
        width: image.width.toDouble(),
        height: image.height.toDouble(),
        size: bytes.length,
      );
    case AttachmentKind.file:
      final file = await FilePicker.pickFile();
      if (file == null) return null;
      final bytes = await file.readAsBytes();
      final upload = await chat.uploadAsset(room, file.name, bytes);
      return core.Message.file(
        id: const Uuid().v7(),
        authorId: authorId,
        source: upload.url,
        name: file.name,
        size: bytes.length,
        mimeType: upload.mimeType,
      );
    case AttachmentKind.audio:
      final recorder = AudioRecorder();
      try {
        if (!await recorder.hasPermission()) return null;
        final format = await _voiceFormat(recorder);
        // Web records into an in-memory blob (the path is ignored); native
        // platforms into a temporary file.
        final path = kIsWeb
            ? ''
            : '${(await getTemporaryDirectory()).path}/${const Uuid().v7()}.${format.extension}';
        await recorder.start(RecordConfig(encoder: format.encoder), path: path);
        if (!context.mounted) return null;
        final samples = <double>[];
        final amplitude = recorder
            .onAmplitudeChanged(const Duration(milliseconds: 100))
            // dBFS (-160..0) -> 0..1, keeping the audible -50..0 dB range.
            .listen(
              (a) => samples.add(((a.current + 50) / 50).clamp(0.0, 1.0)),
            );
        final duration = await showModalBottomSheet<Duration>(
          context: context,
          isDismissible: false,
          enableDrag: false,
          builder: (_) => _RecordingSheet(samples: samples),
        );
        await amplitude.cancel();
        final recorded = await recorder.stop();
        if (recorded == null || duration == null) return null;
        final bytes = kIsWeb
            ? (await http.get(Uri.parse(recorded))).bodyBytes
            : await File(recorded).readAsBytes();
        if (bytes.isEmpty) return null;
        final upload = await chat.uploadAsset(
          room,
          'voice.${format.extension}',
          bytes,
        );
        return core.Message.audio(
          id: const Uuid().v7(),
          authorId: authorId,
          source: upload.url,
          duration: duration,
          size: bytes.length,
          waveform: downsampleWaveform(samples),
        );
      } finally {
        await recorder.dispose();
      }
  }
}

typedef _VoiceFormat = ({AudioEncoder encoder, String extension});

/// Best voice recording format the platform supports: AAC in an M4A
/// container where available (every native platform), Opus in WebM in
/// browsers (Chrome/Firefox can't encode AAC), WAV as a last resort.
Future<_VoiceFormat> _voiceFormat(AudioRecorder recorder) async {
  const candidates = <_VoiceFormat>[
    (encoder: AudioEncoder.aacLc, extension: 'm4a'),
    (encoder: AudioEncoder.opus, extension: 'webm'),
    (encoder: AudioEncoder.wav, extension: 'wav'),
  ];
  for (final format in candidates) {
    if (await recorder.isEncoderSupported(format.encoder)) return format;
  }
  return candidates.last;
}

/// MIME type of a voice message from its file extension (the audio player
/// needs it to decode the downloaded bytes, especially on the web).
String voiceMimeType(String source) {
  final path = Uri.tryParse(source)?.path.toLowerCase() ?? '';
  if (path.endsWith('.webm')) return 'audio/webm';
  if (path.endsWith('.ogg') || path.endsWith('.opus')) return 'audio/ogg';
  if (path.endsWith('.wav')) return 'audio/wav';
  if (path.endsWith('.mp3')) return 'audio/mpeg';
  return 'audio/mp4';
}

/// Extensions [openFileMessage] hands to the system viewer after saving:
/// documents and media only. Anything else (scripts, executables, archives,
/// office files with macros, ...) is saved but not opened: a file message is
/// sent by another member, who picks its name and content.
const _openableExtensions = {
  'pdf',
  'txt',
  'csv',
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'heic',
  'mp3',
  'm4a',
  'aac',
  'wav',
  'ogg',
  'mp4',
  'mov',
  'webm',
};

/// A file name safe to save locally: the last path segment of [name] with
/// any character other than letters, digits, `.`, `_` and `-` replaced, so
/// a sender can't make the download land outside the downloads folder.
String safeDownloadName(String name) {
  final base = name.split(RegExp(r'[/\\]')).last.trim();
  final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return safe.isEmpty || RegExp(r'^\.+$').hasMatch(safe) ? 'download' : safe;
}

/// Downloads a file message (with the auth headers when it is stored in this
/// project's Storage), saves it and, for documents and media, opens it once
/// the user confirms.
Future<void> openFileMessage(
  BuildContext context,
  core.FileMessage message,
) async {
  final response = await http.get(
    Uri.parse(message.source),
    headers: SupabaseChatCore.instance.httpSupabaseHeadersFor(message.source),
  );
  if (response.statusCode != 200) {
    throw SupabaseChatCoreStorageException(
      'Download failed (${response.statusCode})',
    );
  }
  final name = safeDownloadName(message.name);
  final saved = await FileSaver.instance.saveFile(
    name: name,
    bytes: response.bodyBytes,
  );
  if (kIsWeb || !context.mounted) return;
  final extension = name.contains('.')
      ? name.split('.').last.toLowerCase()
      : '';
  if (!_openableExtensions.contains(extension)) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved to $saved')));
    return;
  }
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Open file?'),
      content: Text('"$name" was saved to your device. Open it now?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Open'),
        ),
      ],
    ),
  );
  if (open ?? false) await OpenFilex.open(saved);
}

/// Reduces [samples] to [bars] values (max of each bucket), the resolution
/// a voice message bubble draws.
List<double> downsampleWaveform(List<double> samples, {int bars = 48}) {
  if (samples.isEmpty) return const [];
  if (samples.length <= bars) return List.of(samples);
  final bucket = samples.length / bars;
  return [
    for (var i = 0; i < bars; i++)
      samples
          .sublist((i * bucket).floor(), ((i + 1) * bucket).floor())
          .fold(0.0, (a, b) => a > b ? a : b),
  ];
}

class _RecordingSheet extends StatefulWidget {
  const _RecordingSheet({required this.samples});

  /// Live amplitude samples (0..1), appended by the recorder.
  final List<double> samples;

  @override
  State<_RecordingSheet> createState() => _RecordingSheetState();
}

class _RecordingSheetState extends State<_RecordingSheet>
    with SingleTickerProviderStateMixin {
  final _stopwatch = Stopwatch()..start();
  late final Timer _timer;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            ScaleTransition(
              scale: Tween(begin: .9, end: 1.1).animate(_pulse),
              child: CircleAvatar(
                radius: 36,
                backgroundColor: scheme.errorContainer,
                child: Icon(Icons.mic_rounded, size: 36, color: scheme.error),
              ),
            ),
            SizedBox(
              height: 40,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 2,
                children: [
                  for (final v
                      in widget.samples.length > 40
                          ? widget.samples.sublist(widget.samples.length - 40)
                          : widget.samples)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      width: 3,
                      height: 4 + v * 36,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
            ),
            Text(
              formatDuration(_stopwatch.elapsed),
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Row(
              spacing: 12,
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pop(context, _stopwatch.elapsed),
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('Send'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
