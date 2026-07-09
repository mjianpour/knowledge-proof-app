import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/progress_ticker.dart';
import '../widgets/rich_content.dart';

class ChallengePage extends StatefulWidget {
  const ChallengePage({super.key, this.target = 1, this.topicIds = const []});

  /// How many questions today's session should hold (home page slider).
  final int target;

  /// Topics the user selected; empty means the scheduler chooses automatically.
  final List<String> topicIds;

  @override
  State<ChallengePage> createState() => _ChallengePageState();
}

class _ChallengePageState extends State<ChallengePage> {
  // Today's session questions (pending + answered), oldest first.
  List<Map<String, dynamic>> _items = [];
  // Full history for the sidebar, newest first.
  List<Map<String, dynamic>> _history = [];
  String? _currentId;

  // One answer draft per pending question, so switching questions never
  // loses what was typed.
  final Map<String, TextEditingController> _drafts = {};
  // Fresh evaluation responses (richer than the stored combined text).
  final Map<String, Map<String, dynamic>> _evals = {};

  int _answeredToday = 0;
  String? _error;
  bool _loading = true;
  bool _submitting = false;
  bool _sidebarOpen = true;

  @override
  void initState() {
    super.initState();
    _startSession(widget.target);
  }

  @override
  void dispose() {
    for (final controller in _drafts.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _draftFor(String id) =>
      _drafts.putIfAbsent(id, TextEditingController.new);

  // ---------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------

  Future<void> _startSession(int count) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await Api.startSession(count, widget.topicIds);
      final items =
          (result['questions'] as List<dynamic>).cast<Map<String, dynamic>>();
      setState(() {
        _items = items;
        _answeredToday = result['answered_today'] as int? ?? 0;
        _currentId = _firstPendingId() ?? (items.isEmpty ? null : items.last['id'] as String);
        _loading = false;
      });
      _loadHistory();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  String? _firstPendingId() {
    for (final item in _items) {
      if (item['status'] == 'pending') return item['id'] as String;
    }
    return null;
  }

  Future<void> _loadHistory() async {
    try {
      final rows = await Api.listChallenges();
      setState(() => _history = rows.cast<Map<String, dynamic>>());
    } catch (_) {
      // Sidebar is a convenience — never block the main flow on it.
    }
  }

  Map<String, dynamic>? _findItem(String? id) {
    if (id == null) return null;
    for (final item in _items) {
      if (item['id'] == id) return item;
    }
    for (final item in _history) {
      if (item['id'] == id) return item;
    }
    return null;
  }

  Future<void> _submit(Map<String, dynamic> item) async {
    final id = item['id'] as String;
    final answer = _draftFor(id).text.trim();
    if (answer.isEmpty) return;
    setState(() => _submitting = true);
    try {
      final result = await Api.answerChallenge(id, answer);
      setState(() {
        _evals[id] = result;
        item['status'] = 'answered';
        item['score'] = result['score'];
        item['user_answer'] = answer;
        _answeredToday = result['answered_today'] as int? ?? _answeredToday + 1;
        _submitting = false;
      });
      _loadHistory();
    } catch (e) {
      setState(() => _submitting = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Evaluation failed: $e')));
      }
    }
  }

  // ---------------------------------------------------------------------
  // Leaving with unsubmitted answers
  // ---------------------------------------------------------------------

  bool get _hasUnsavedDrafts {
    for (final item in _items) {
      if (item['status'] == 'pending' &&
          (_drafts[item['id']]?.text.trim().isNotEmpty ?? false)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _confirmLeave() async {
    if (!_hasUnsavedDrafts) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave this session?'),
        content: const Text(
            'You have unsubmitted answers — they are not saved and will be '
            'lost if you leave.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Stay')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Leave anyway')),
        ],
      ),
    );
    return leave ?? false;
  }

  Future<void> _leave() async {
    if (await _confirmLeave() && mounted) Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------------
  // Navigation (sidebar + previous/next arrows)
  // ---------------------------------------------------------------------

  List<Map<String, dynamic>> get _chronological =>
      _history.reversed.toList(growable: false);

  int _currentIndex() {
    final list = _chronological;
    final index = list.indexWhere((e) => e['id'] == _currentId);
    return index < 0 ? list.length - 1 : index;
  }

  void _goTo(int index) {
    final list = _chronological;
    if (index < 0 || index >= list.length) return;
    setState(() => _currentId = list[index]['id'] as String);
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = _items.length;
    final title = total > 1
        ? "Today's Challenges ($_answeredToday of $total done)"
        : "Today's Challenge";
    final index = _currentIndex();
    final count = _chronological.length;
    final canPrev = count > 0 && index > 0;
    final canNext = count > 0 && index < count - 1;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          // Gemini-style: the sidebar hamburger lives at the top-left.
          leading: IconButton(
            tooltip:
                _sidebarOpen ? 'Hide question list' : 'Show question list',
            icon: Icon(_sidebarOpen ? Icons.menu_open : Icons.menu),
            onPressed: () => setState(() => _sidebarOpen = !_sidebarOpen),
          ),
          title: Text(title),
          actions: [
            IconButton(
              tooltip: 'Back to home',
              icon: const Icon(Icons.home_outlined),
              onPressed: _leave,
            ),
          ],
        ),
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Smoothly slides open/closed instead of popping in and out.
            AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeInOutCubic,
              width: _sidebarOpen ? 300 : 0,
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(
                  right: BorderSide(
                    color: _sidebarOpen
                        ? scheme.outlineVariant
                        : Colors.transparent,
                  ),
                ),
              ),
              child: ClipRect(
                child: OverflowBox(
                  minWidth: 300,
                  maxWidth: 300,
                  alignment: Alignment.topLeft,
                  child: _sidebar(context),
                ),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: IconButton.filledTonal(
                      tooltip: 'Previous question',
                      icon: const Icon(Icons.chevron_left),
                      onPressed: canPrev ? () => _goTo(index - 1) : null,
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 800),
                        child: _mainView(context),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: IconButton.filledTonal(
                      tooltip: 'Next question',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: canNext ? () => _goTo(index + 1) : null,
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

  Widget _mainView(BuildContext context) {
    if (_loading) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(widget.target > 1
              ? 'Generating your ${widget.target} challenges from your notes and books...'
              : 'Generating your challenge from your notes and books...'),
          const SizedBox(height: 20),
          const ProgressTicker(),
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
                onPressed: () => _startSession(widget.target),
                child: const Text('Try again')),
          ],
        ),
      );
    }
    final item = _findItem(_currentId);
    if (item == null) {
      return const Text('Select a question from the list.');
    }
    if (item['status'] == 'pending') return _questionView(context, item);
    final eval = _evals[item['id']];
    if (eval != null) return _freshEvaluationView(context, item, eval);
    return _readOnlyView(context, item);
  }

  // ---------------------------------------------------------------------
  // Sidebar
  // ---------------------------------------------------------------------

  String _today() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _plainPreview(String markdown) {
    var text = markdown
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' [code] ')
        .replaceAll(RegExp(r'\$\$[\s\S]*?\$\$'), ' [math] ')
        .replaceAll(RegExp(r'[#*_`>\$]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length > 70 ? '${text.substring(0, 70)}…' : text;
  }

  Widget _sidebar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[];
    String? lastDate;
    for (final item in _history) {
      final date = item['date'] as String? ?? '';
      if (date != lastDate) {
        lastDate = date;
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            date == _today() ? 'Today' : date,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.primary, fontWeight: FontWeight.bold),
          ),
        ));
      }
      children.add(_sidebarTile(context, item));
    }
    if (children.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.all(16),
        child: Text('No questions yet.'),
      ));
    }
    return ListView(children: children);
  }

  Widget _sidebarTile(BuildContext context, Map<String, dynamic> item) {
    final scheme = Theme.of(context).colorScheme;
    // Session copies are fresher than history right after an answer.
    final live = _findItem(item['id'] as String) ?? item;
    final answered = live['status'] == 'answered';
    final score = live['score'] as int?;
    final hasDraft = !answered &&
        (_drafts[item['id']]?.text.trim().isNotEmpty ?? false);

    return ListTile(
      dense: true,
      selected: item['id'] == _currentId,
      selectedTileColor: scheme.surfaceContainerHighest,
      leading: answered
          ? CircleAvatar(
              radius: 14,
              backgroundColor: (score ?? 0) > 75
                  ? const Color(0xFF30A14E)
                  : scheme.errorContainer,
              child: Text('$score',
                  style: TextStyle(
                      fontSize: 10,
                      color: (score ?? 0) > 75
                          ? Colors.white
                          : scheme.onErrorContainer)),
            )
          : Icon(hasDraft ? Icons.edit_note : Icons.hourglass_empty,
              size: 20, color: scheme.primary),
      title: Text(item['topic'] as String? ?? '?',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
      subtitle: Text(
        _plainPreview(item['question'] as String? ?? ''),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5),
      ),
      onTap: () => setState(() => _currentId = item['id'] as String),
    );
  }

  // ---------------------------------------------------------------------
  // Pending question (answerable)
  // ---------------------------------------------------------------------

  Widget _questionView(BuildContext context, Map<String, dynamic> item) {
    final position = _items.indexWhere((e) => e['id'] == item['id']) + 1;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Chip(
              avatar: const Icon(Icons.school, size: 18),
              label: Text(item['topic'] as String? ?? '?'),
            ),
            if (_items.length > 1 && position > 0) ...[
              const SizedBox(width: 8),
              Chip(
                avatar: const Icon(Icons.format_list_numbered, size: 18),
                label: Text('Question $position of ${_items.length}'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: RichContent(item['question'] as String? ?? ''),
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _draftFor(item['id'] as String),
          maxLines: 10,
          minLines: 5,
          enabled: !_submitting,
          decoration: const InputDecoration(
            labelText: 'Your answer',
            hintText:
                'Explain the mechanism — WHY it happens, not just what to change.',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _submitting ? null : () => _submit(item),
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
        if (_submitting) ...[
          const SizedBox(height: 16),
          const Center(child: ProgressTicker(lines: 3)),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Fresh evaluation (just answered in this session)
  // ---------------------------------------------------------------------

  Widget _freshEvaluationView(BuildContext context, Map<String, dynamic> item,
      Map<String, dynamic> eval) {
    final score = eval['score'] as int? ?? 0;
    final passed = score > 75;
    final scheme = Theme.of(context).colorScheme;
    final symptomNote = (eval['symptom_patching_note'] as String? ?? '').trim();

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Chip(
              avatar: const Icon(Icons.school, size: 18),
              label: Text(item['topic'] as String? ?? '?'),
            ),
          ],
        ),
        const SizedBox(height: 16),
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
                RichContent(eval['feedback'] as String? ?? '', fontSize: 15),
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
                  RichContent(symptomNote, fontSize: 15),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        _sessionFooter(context),
      ],
    );
  }

  Widget _sessionFooter(BuildContext context) {
    final nextPendingId = _firstPendingId();
    if (nextPendingId != null) {
      final position =
          _items.indexWhere((e) => e['id'] == nextPendingId) + 1;
      final remaining =
          _items.where((e) => e['status'] == 'pending').length;
      return Column(
        children: [
          Text('$remaining question${remaining == 1 ? '' : 's'} left in this session',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _leave,
                icon: const Icon(Icons.home),
                label: const Text('Stop for now'),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: () =>
                    setState(() => _currentId = nextPendingId),
                icon: const Icon(Icons.arrow_forward),
                label: Text('Next question ($position of ${_items.length})'),
              ),
            ],
          ),
        ],
      );
    }
    return Column(
      children: [
        Text(
          _items.length > 1
              ? '🎉 Session complete — ${_items.length} challenges done today!'
              : 'Done for today!',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _leave,
              icon: const Icon(Icons.home),
              label: const Text('Back home'),
            ),
            const SizedBox(width: 16),
            FilledButton.tonalIcon(
              onPressed: () => _startSession(_items.length + 1),
              icon: const Icon(Icons.add),
              label: const Text('One more anyway'),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Read-only view of a past challenge
  // ---------------------------------------------------------------------

  Widget _readOnlyView(BuildContext context, Map<String, dynamic> item) {
    final scheme = Theme.of(context).colorScheme;
    final answered = item['status'] == 'answered';
    final score = item['score'] as int? ?? 0;
    final passed = score > 75;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Chip(
              avatar: const Icon(Icons.school, size: 18),
              label: Text(item['topic'] as String? ?? '?'),
            ),
            const SizedBox(width: 8),
            Chip(
              avatar: const Icon(Icons.history, size: 18),
              label: Text(item['date'] as String? ?? ''),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: RichContent(item['question'] as String? ?? ''),
          ),
        ),
        if (answered) ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your answer',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  RichContent(item['user_answer'] as String? ?? '',
                      fontSize: 15),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: passed ? scheme.primaryContainer : scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Evaluation — $score / 100',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  RichContent(item['evaluation'] as String? ?? '',
                      fontSize: 15),
                ],
              ),
            ),
          ),
        ] else ...[
          const SizedBox(height: 16),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Text('Not answered yet.'),
            ),
          ),
        ],
      ],
    );
  }
}
