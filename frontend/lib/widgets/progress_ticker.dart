import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';

/// Polls the backend's progress log while visible and shows the latest
/// messages, so the user sees exactly what is happening during long
/// operations instead of a bare spinner.
class ProgressTicker extends StatefulWidget {
  const ProgressTicker({super.key, this.lines = 5});

  final int lines;

  @override
  State<ProgressTicker> createState() => _ProgressTickerState();
}

class _ProgressTickerState extends State<ProgressTicker> {
  Timer? _timer;
  List<String> _messages = [];

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(milliseconds: 900), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final snapshot = await Api.progress();
      final events =
          (snapshot['events'] as List<dynamic>).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _messages = events
            .map((e) => e['msg'] as String? ?? '')
            .where((m) => m.isNotEmpty)
            .toList();
        if (_messages.length > widget.lines) {
          _messages = _messages.sublist(_messages.length - widget.lines);
        }
      });
    } catch (_) {
      // Progress is best-effort; never surface polling errors.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_messages.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _messages.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                _messages[i],
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: scheme.onSurface.withValues(
                      alpha: i == _messages.length - 1 ? 1.0 : 0.55),
                  fontWeight: i == _messages.length - 1
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
