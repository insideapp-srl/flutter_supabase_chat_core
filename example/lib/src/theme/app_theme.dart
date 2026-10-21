import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart' as core;

/// Telegram-like accent blue the whole Material 3 palette is derived from.
const _seed = Color(0xFF3390EC);

/// Chat-specific colors (bubbles, wallpaper), Telegram-inspired, exposed
/// as a [ThemeExtension] so every widget picks the right light/dark set.
@immutable
class ChatPalette extends ThemeExtension<ChatPalette> {
  const ChatPalette({
    required this.sentBubble,
    required this.onSentBubble,
    required this.sentMeta,
    required this.receivedBubble,
    required this.onReceivedBubble,
    required this.receivedMeta,
    required this.wallpaper,
    required this.wallpaperPattern,
    required this.serviceChip,
    required this.onServiceChip,
    required this.accent,
  });

  static const light = ChatPalette(
    sentBubble: Color(0xFFEEFFDE),
    onSentBubble: Color(0xFF000000),
    sentMeta: Color(0xFF4FAE4E),
    receivedBubble: Color(0xFFFFFFFF),
    onReceivedBubble: Color(0xFF000000),
    receivedMeta: Color(0xFFA1AAB3),
    wallpaper: [Color(0xFFDCE8C4), Color(0xFFB9D7A5), Color(0xFFD7DFAE)],
    wallpaperPattern: Color(0x1A2F4F1F),
    serviceChip: Color(0x5A3D5A2B),
    onServiceChip: Color(0xFFFFFFFF),
    accent: Color(0xFF3390EC),
  );

  static const dark = ChatPalette(
    sentBubble: Color(0xFF2B5278),
    onSentBubble: Color(0xFFFFFFFF),
    sentMeta: Color(0xFF7DA8D3),
    receivedBubble: Color(0xFF182533),
    onReceivedBubble: Color(0xFFFFFFFF),
    receivedMeta: Color(0xFF6D7F8F),
    wallpaper: [Color(0xFF0E1621), Color(0xFF13202D), Color(0xFF0F1A26)],
    wallpaperPattern: Color(0x10FFFFFF),
    serviceChip: Color(0x661E2C3A),
    onServiceChip: Color(0xFFFFFFFF),
    accent: Color(0xFF64B5EF),
  );

  final Color sentBubble;
  final Color onSentBubble;
  final Color sentMeta;
  final Color receivedBubble;
  final Color onReceivedBubble;
  final Color receivedMeta;
  final List<Color> wallpaper;
  final Color wallpaperPattern;
  final Color serviceChip;
  final Color onServiceChip;
  final Color accent;

  static ChatPalette of(BuildContext context) =>
      Theme.of(context).extension<ChatPalette>() ?? light;

  @override
  ChatPalette copyWith() => this;

  @override
  ChatPalette lerp(ChatPalette? other, double t) =>
      other == null || t < .5 ? this : other;
}

/// App-wide theme, light and dark, plus the matching chat theme.
abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light);

  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    var scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
    );
    scheme = scheme.copyWith(
      primary: dark ? const Color(0xFF64B5EF) : _seed,
      onPrimary: Colors.white,
      surface: dark ? const Color(0xFF17212B) : Colors.white,
      surfaceContainerLow: dark
          ? const Color(0xFF1C2733)
          : const Color(0xFFF4F4F5),
      surfaceContainer: dark
          ? const Color(0xFF202B36)
          : const Color(0xFFF1F2F4),
      surfaceContainerHigh: dark
          ? const Color(0xFF242F3D)
          : const Color(0xFFEBEDF0),
      surfaceContainerHighest: dark
          ? const Color(0xFF2B3744)
          : const Color(0xFFE4E7EB),
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      extensions: [dark ? ChatPalette.dark : ChatPalette.light],
    );
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: .5,
        shadowColor: Colors.black26,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        showDragHandle: true,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: .4),
        space: 1,
        thickness: .5,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// `flutter_chat_ui` theme derived from [theme].
  ///
  /// Built field by field rather than with `ChatTheme.fromThemeData`: since
  /// flutter_chat_core 2.9.1 that factory takes the experimental
  /// `material_ui` package's ThemeData, not Flutter's.
  static core.ChatTheme chatTheme(ThemeData theme) {
    final scheme = theme.colorScheme;
    final palette = theme.extension<ChatPalette>() ?? ChatPalette.light;
    final text = theme.textTheme;
    TextStyle style(TextStyle? s) => s ?? const TextStyle();
    return core.ChatTheme(
      colors: core.ChatColors(
        primary: palette.sentBubble,
        onPrimary: palette.onSentBubble,
        surface: scheme.surface,
        onSurface: scheme.onSurface,
        surfaceContainerLow: scheme.surfaceContainerLow,
        surfaceContainer: palette.receivedBubble,
        surfaceContainerHigh: scheme.surfaceContainerHigh,
      ),
      typography: core.ChatTypography(
        bodyLarge: style(text.bodyLarge),
        bodyMedium: style(text.bodyMedium),
        bodySmall: style(text.bodySmall),
        labelLarge: style(text.labelLarge),
        labelMedium: style(text.labelMedium),
        labelSmall: style(text.labelSmall),
      ),
      shape: const BorderRadius.all(Radius.circular(16)),
    );
  }
}

/// Deterministic avatar color for [seed] (e.g. a user id), from the same
/// set of hues Telegram uses for its letter avatars.
Color avatarColor(String seed, ColorScheme scheme) {
  const colors = [
    Color(0xFFE17076),
    Color(0xFFFAA774),
    Color(0xFFA695E7),
    Color(0xFF7BC862),
    Color(0xFF6EC9CB),
    Color(0xFF65AADD),
    Color(0xFFEE7AAE),
  ];
  return colors[seed.hashCode.abs() % colors.length];
}
