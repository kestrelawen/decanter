import 'package:flutter/material.dart';

import 'glass.dart';

/// Renders message text with support for inline images (`![](url)`) and formatted
/// roleplay text (`*actions*`).
class ChatRichContent extends StatelessWidget {
  const ChatRichContent({
    super.key,
    required this.text,
    required this.isUser,
  });

  final String text;
  final bool isUser;

  static final RegExp _htmlCommentPattern = RegExp(
    r'<!--[\s\S]*?-->',
  );

  static final RegExp _imagePattern = RegExp(
    r'!\[(.*?)\]\((.*?)\)|<(?:img|image)\b([^>]*?)(?:\/?>|>)(?:\s*<\/(?:img|image)>)?',
    caseSensitive: false,
    dotAll: true,
  );

  static final RegExp _srcAttrPattern = RegExp(
    r'''src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );

  static final RegExp _altAttrPattern = RegExp(
    r'''alt\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final List<_ContentSegment> segments = _parseSegments(text);

    if (segments.isEmpty) {
      return const SizedBox.shrink();
    }

    if (segments.length == 1 && segments.first is _TextSegment) {
      return _buildFormattedText(
        (segments.first as _TextSegment).content,
        context,
      );
    }

    return Column(
      crossAxisAlignment:
          isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < segments.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 6),
          if (segments[i] is _TextSegment)
            _buildFormattedText(
              (segments[i] as _TextSegment).content,
              context,
            )
          else if (segments[i] is _ImageSegment)
            _buildImage((segments[i] as _ImageSegment), context),
        ],
      ],
    );
  }

  List<_ContentSegment> _parseSegments(String raw) {
    final String sanitized = raw.replaceAll(_htmlCommentPattern, '');
    final List<_ContentSegment> segments = <_ContentSegment>[];
    int lastEnd = 0;

    for (final Match match in _imagePattern.allMatches(sanitized)) {
      if (match.start > lastEnd) {
        final String textPart = sanitized.substring(lastEnd, match.start).trim();
        if (textPart.isNotEmpty) {
          segments.add(_TextSegment(textPart));
        }
      }

      String alt = '';
      String rawUrl = '';

      if (match.group(2) != null) {
        // Markdown image: ![alt](url)
        alt = match.group(1)?.trim() ?? '';
        rawUrl = match.group(2)?.trim() ?? '';
      } else if (match.group(3) != null) {
        // HTML image tag: <img src="..." alt="...">
        final String attrs = match.group(3)!;
        final Match? srcMatch = _srcAttrPattern.firstMatch(attrs);
        rawUrl = (srcMatch?.group(1) ??
                srcMatch?.group(2) ??
                srcMatch?.group(3) ??
                '')
            .trim();
        final Match? altMatch = _altAttrPattern.firstMatch(attrs);
        alt = (altMatch?.group(1) ??
                altMatch?.group(2) ??
                altMatch?.group(3) ??
                '')
            .trim();
      }

      if (rawUrl.isNotEmpty) {
        segments.add(_ImageSegment(alt: alt, url: _normalizeUrl(rawUrl)));
      }

      lastEnd = match.end;
    }

    if (lastEnd < sanitized.length) {
      final String trailing = sanitized.substring(lastEnd).trim();
      if (trailing.isNotEmpty) {
        segments.add(_TextSegment(trailing));
      }
    }

    return segments;
  }

  /// Ensures URLs without an explicit scheme (e.g. `www.example.com/pic.jpg`)
  /// are given https:// so Flutter's image loader can resolve them.
  static String _normalizeUrl(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.startsWith('//')) {
      return 'https:$trimmed';
    }
    if (!trimmed.contains('://')) {
      return 'https://$trimmed';
    }
    return trimmed;
  }

  Widget _buildFormattedText(String content, BuildContext context) {
    final TextStyle baseStyle = TextStyle(
      color: isUser ? Glass.textPrimary : Glass.textSecondary,
      fontSize: 14.5,
      height: 1.42,
    );

    final TextStyle italicStyle = baseStyle.copyWith(
      color: isUser ? Glass.textSecondary : Glass.textFaint,
      fontStyle: FontStyle.italic,
    );

    final TextStyle boldStyle = baseStyle.copyWith(
      fontWeight: FontWeight.w700,
      color: Glass.textPrimary,
    );

    // Parses asterisks (*action* for italic, **bold** for bold)
    final List<InlineSpan> spans = _buildTextSpans(
      content,
      base: baseStyle,
      italic: italicStyle,
      bold: boldStyle,
    );

    return Text.rich(
      TextSpan(children: spans),
      style: baseStyle,
    );
  }

  List<InlineSpan> _buildTextSpans(
    String content, {
    required TextStyle base,
    required TextStyle italic,
    required TextStyle bold,
  }) {
    final List<InlineSpan> spans = <InlineSpan>[];
    final RegExp tokenPattern = RegExp(r'(\*\*[^*]+\*\*|\*[^*]+\*)');
    int last = 0;

    for (final Match match in tokenPattern.allMatches(content)) {
      if (match.start > last) {
        spans.add(TextSpan(text: content.substring(last, match.start)));
      }

      final String token = match.group(0)!;
      if (token.startsWith('**') && token.endsWith('**') && token.length > 4) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: bold,
          ),
        );
      } else if (token.startsWith('*') &&
          token.endsWith('*') &&
          token.length > 2) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: italic,
          ),
        );
      } else {
        spans.add(TextSpan(text: token));
      }

      last = match.end;
    }

    if (last < content.length) {
      spans.add(TextSpan(text: content.substring(last)));
    }

    return spans.isEmpty ? <InlineSpan>[TextSpan(text: content)] : spans;
  }

  Widget _buildImage(_ImageSegment segment, BuildContext context) {
    return GestureDetector(
      onTap: () => _openFullScreenImage(context, segment.url, segment.alt),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(
            maxHeight: 280,
            maxWidth: double.infinity,
          ),
          decoration: BoxDecoration(
            color: Glass.shade(0.35),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Glass.tint(0.12), width: 0.8),
          ),
          child: Image.network(
            segment.url,
            fit: BoxFit.cover,
            loadingBuilder: (
              BuildContext ctx,
              Widget child,
              ImageChunkEvent? loadingProgress,
            ) {
              if (loadingProgress == null) return child;
              return Container(
                height: 160,
                color: Glass.tint(0.04),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Glass.tint(0.7),
                      ),
                    ),
                  ),
                ),
              );
            },
            errorBuilder: (
              BuildContext ctx,
              Object error,
              StackTrace? stackTrace,
            ) {
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                color: Glass.shade(0.4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(
                      Icons.broken_image_rounded,
                      size: 20,
                      color: Glass.textFaint,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        segment.alt.isNotEmpty
                            ? segment.alt
                            : 'Image unavailable',
                        style: const TextStyle(
                          color: Glass.textFaint,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _openFullScreenImage(BuildContext context, String url, String alt) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (BuildContext dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(12),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              InteractiveViewer(
                maxScale: 4.0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_rounded,
                      color: Colors.white54,
                      size: 48,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

sealed class _ContentSegment {}

class _TextSegment extends _ContentSegment {
  _TextSegment(this.content);
  final String content;
}

class _ImageSegment extends _ContentSegment {
  _ImageSegment({required this.alt, required this.url});
  final String alt;
  final String url;
}
