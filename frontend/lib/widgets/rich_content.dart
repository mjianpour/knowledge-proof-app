import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// Renders LLM output properly instead of raw text: GitHub-flavored markdown,
/// fenced code in a styled code box, and LaTeX math ($...$, $$...$$) as real
/// mathematical notation.
class RichContent extends StatelessWidget {
  const RichContent(this.text, {super.key, this.fontSize = 16});

  final String text;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SelectionArea(
      child: GptMarkdown(
        text,
        style: TextStyle(fontSize: fontSize, height: 1.65),
        codeBuilder: (context, name, code, closed) =>
            _CodeBox(language: name, code: code),
        highlightBuilder: (context, inlineCode, style) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            inlineCode,
            style: GoogleFonts.jetBrainsMono(
              fontSize: (style.fontSize ?? fontSize) * 0.9,
              color: scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.language, required this.code});

  final String language;
  final String code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (language.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 14, top: 8),
              child: Text(
                language,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.55),
                      letterSpacing: 0.5,
                    ),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(14),
            child: Text(
              code.trimRight(),
              style: GoogleFonts.jetBrainsMono(
                fontSize: 13.5,
                height: 1.55,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
