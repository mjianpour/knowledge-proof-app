import 'package:flutter/material.dart';

import '../api.dart';

class ChallengePage extends StatefulWidget {
  const ChallengePage({super.key});

  @override
  State<ChallengePage> createState() => _ChallengePageState();
}

class _ChallengePageState extends State<ChallengePage> {
  final _answerController = TextEditingController();

  Map<String, dynamic>? _challenge;
  Map<String, dynamic>? _evaluation;
  String? _error;
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _fetchChallenge();
  }

  @override
  void dispose() {
    _answerController.dispose();
    super.dispose();
  }

  Future<void> _fetchChallenge() async {
    setState(() {
      _loading = true;
      _error = null;
      _evaluation = null;
      _answerController.clear();
    });
    try {
      final challenge = await Api.todaysChallenge();
      setState(() {
        _challenge = challenge;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _submit() async {
    final answer = _answerController.text.trim();
    if (answer.isEmpty || _challenge == null) return;
    setState(() => _submitting = true);
    try {
      final result =
          await Api.answerChallenge(_challenge!['id'] as String, answer);
      setState(() {
        _evaluation = result;
        _submitting = false;
      });
    } catch (e) {
      setState(() => _submitting = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Evaluation failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Today's Challenge")),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Generating your challenge from your notes and books...'),
        ],
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
                onPressed: _fetchChallenge, child: const Text('Try again')),
          ],
        ),
      );
    }

    final challenge = _challenge!;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Chip(
              avatar: const Icon(Icons.school, size: 18),
              label: Text(challenge['topic'] as String? ?? '?'),
            ),
            if (challenge['resumed'] == true) ...[
              const SizedBox(width: 8),
              const Chip(label: Text('resumed from earlier today')),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SelectableText(
              challenge['question'] as String? ?? '',
              style: const TextStyle(fontSize: 16, height: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 24),
        if (_evaluation == null) ...[
          TextField(
            controller: _answerController,
            maxLines: 10,
            minLines: 5,
            enabled: !_submitting,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Your answer',
              hintText:
                  'Explain the mechanism — WHY it happens, not just what to change.',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_submitting ? 'Evaluating...' : 'Submit answer'),
            ),
          ),
        ] else
          _evaluationView(context, _evaluation!),
      ],
    );
  }

  Widget _evaluationView(BuildContext context, Map<String, dynamic> eval) {
    final score = eval['score'] as int? ?? 0;
    final passed = score > 75;
    final scheme = Theme.of(context).colorScheme;
    final symptomNote = (eval['symptom_patching_note'] as String? ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: passed ? scheme.primaryContainer : scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text('$score / 100',
                    style: Theme.of(context)
                        .textTheme
                        .displaySmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(passed
                    ? 'Passed — interval doubled (next review: ${eval['next_review_date']})'
                    : 'Below 75 — back to daily review (next review: ${eval['next_review_date']})'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Feedback',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SelectableText(eval['feedback'] as String? ?? '',
                    style: const TextStyle(height: 1.5)),
              ],
            ),
          ),
        ),
        if (symptomNote.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            color: scheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.healing),
                      const SizedBox(width: 8),
                      Text('Symptom patching detected',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(symptomNote,
                      style: const TextStyle(height: 1.5)),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.home),
              label: const Text('Done for now'),
            ),
            const SizedBox(width: 16),
            FilledButton.icon(
              onPressed: _fetchChallenge,
              icon: const Icon(Icons.refresh),
              label: const Text('Another challenge'),
            ),
          ],
        ),
      ],
    );
  }
}
