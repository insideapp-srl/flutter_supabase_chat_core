import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:provider/provider.dart';

/// Message composer laid out as in messaging apps: attachment button, text
/// field, and on the right the send button, which becomes a microphone
/// (record a voice message) while the field is empty.
///
/// A drop-in replacement of `flutter_chat_ui`'s `Composer` (which has no slot
/// for an extra button) for `Chat`'s `composerBuilder`: it sends through the
/// chat's `onMessageSend`, opens its `onAttachmentTap` and reports its height
/// to the message list the same way.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.textEditingController,
    required this.focusNode,
    this.hintText = 'Message',
    this.onRecordVoice,
    this.sendOnEnter = false,
    this.topWidget,
    this.backgroundColor,
    this.inputFillColor,
  });

  /// Controller of the text field, owned by the caller.
  final TextEditingController textEditingController;

  /// Focus of the text field, owned by the caller.
  final FocusNode focusNode;

  final String hintText;

  /// Records a voice message, from the microphone shown while the field is
  /// empty. Without it the send button is always shown.
  final VoidCallback? onRecordVoice;

  /// Whether Enter sends (Shift+Enter then adds a new line), as on desktop.
  final bool sendOnEnter;

  /// Shown above the field (e.g. the message being replied to).
  final Widget? topWidget;

  final Color? backgroundColor;
  final Color? inputFillColor;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final _key = GlobalKey();
  late bool _hasText = _text.text.trim().isNotEmpty;

  TextEditingController get _text => widget.textEditingController;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
    widget.focusNode.onKeyEvent = _onKeyEvent;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.textEditingController != widget.textEditingController) {
      oldWidget.textEditingController.removeListener(_onTextChanged);
      _text.addListener(_onTextChanged);
    }
    // The reply preview above the field changes its height.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    widget.focusNode.onKeyEvent = null;
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _text.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        widget.sendOnEnter ^ HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _send() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    context.read<OnMessageSendCallback?>()?.call(text);
    _text.clear();
  }

  /// Tells the message list how much room to leave at the bottom.
  void _measure() {
    if (!mounted) return;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    context.read<ComposerHeightNotifier>().setHeight(
      box.size.height - MediaQuery.of(context).padding.bottom,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onAttachmentTap = context.read<OnAttachmentTapCallback?>();
    final showMic = !_hasText && widget.onRecordVoice != null;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        key: _key,
        color: widget.backgroundColor ?? scheme.surfaceContainerLow,
        child: Column(
          children: [
            ?widget.topWidget,
            Padding(
              padding: const EdgeInsets.all(8).add(
                EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom),
              ),
              child: Row(
                spacing: 8,
                children: [
                  if (onAttachmentTap != null)
                    IconButton(
                      icon: const Icon(Icons.attach_file),
                      tooltip: 'Attach',
                      color: scheme.onSurfaceVariant,
                      onPressed: onAttachmentTap,
                    ),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      focusNode: widget.focusNode,
                      minLines: 1,
                      maxLines: 3,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: widget.hintText,
                        border: const OutlineInputBorder(
                          borderSide: BorderSide.none,
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                        filled: true,
                        fillColor:
                            widget.inputFillColor ??
                            scheme.surfaceContainerHigh,
                        hoverColor: Colors.transparent,
                      ),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    transitionBuilder: (child, animation) =>
                        ScaleTransition(scale: animation, child: child),
                    child: showMic
                        ? IconButton(
                            key: const ValueKey('mic'),
                            icon: const Icon(Icons.mic_none_rounded),
                            tooltip: 'Record a voice message',
                            color: scheme.primary,
                            onPressed: widget.onRecordVoice,
                          )
                        : IconButton(
                            key: const ValueKey('send'),
                            icon: const Icon(Icons.send),
                            tooltip: 'Send',
                            color: scheme.primary,
                            onPressed: _hasText ? _send : null,
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
