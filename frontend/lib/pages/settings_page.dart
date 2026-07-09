import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _repoController = TextEditingController();
  final _modelController = TextEditingController();
  final _anthropicKeyController = TextEditingController();
  final _openaiKeyController = TextEditingController();
  final _githubTokenController = TextEditingController();

  String _provider = 'anthropic';
  Map<String, dynamic> _settings = {};
  List<dynamic> _topics = [];
  bool _loading = true;
  bool _saving = false;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _repoController.dispose();
    _modelController.dispose();
    _anthropicKeyController.dispose();
    _openaiKeyController.dispose();
    _githubTokenController.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final settings = await Api.getSettings();
      final topics = await Api.listTopics();
      setState(() {
        _settings = settings;
        _topics = topics;
        _provider = settings['llm_provider'] as String? ?? 'anthropic';
        _repoController.text = settings['github_repo_url'] as String? ?? '';
        _modelController.text = settings['llm_model'] as String? ?? '';
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      _toast('Failed to load settings: $e');
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final updates = <String, dynamic>{
        'github_repo_url': _repoController.text,
        'llm_provider': _provider,
        'llm_model': _modelController.text,
      };
      // Keys are write-only: only send when the user typed a new one.
      if (_anthropicKeyController.text.trim().isNotEmpty) {
        updates['anthropic_api_key'] = _anthropicKeyController.text.trim();
      }
      if (_openaiKeyController.text.trim().isNotEmpty) {
        updates['openai_api_key'] = _openaiKeyController.text.trim();
      }
      if (_githubTokenController.text.trim().isNotEmpty) {
        updates['github_token'] = _githubTokenController.text.trim();
      }
      final settings = await Api.updateSettings(updates);
      setState(() {
        _settings = settings;
        _anthropicKeyController.clear();
        _openaiKeyController.clear();
        _githubTokenController.clear();
      });
      _toast('Settings saved.');
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _syncGithub() async {
    setState(() => _syncing = true);
    try {
      final result = await Api.syncGithub();
      _toast('Synced ${result['synced']} notes from ${result['repo']} '
          '(${result['matched_to_topics']} matched to topics).');
    } catch (e) {
      _toast('Sync failed: $e');
    } finally {
      setState(() => _syncing = false);
    }
  }

  Future<void> _uploadPdf(Map<String, dynamic> topic) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );
    final file = picked?.files.firstOrNull;
    if (file == null || file.bytes == null) return;

    _toast('Uploading and distilling "${file.name}" — this takes a minute...');
    try {
      final result =
          await Api.uploadPdf(topic['id'] as String, file.name, file.bytes!);
      _toast('Ingested ${result['filename']}: ${result['chunks_stored']} '
          'chunks + LLM digest (${result['digest_source']}).');
    } catch (e) {
      _toast('PDF upload failed: $e');
    }
  }

  Future<void> _editTopic(Map<String, dynamic> topic) async {
    final nameController =
        TextEditingController(text: topic['name'] as String? ?? '');
    final bookController =
        TextEditingController(text: topic['book_reference'] as String? ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit topic'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Topic name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bookController,
                decoration: const InputDecoration(
                  labelText: 'Reference book',
                  hintText:
                      'e.g. Electrodynamics, Reitz & Milford, 2nd ed., ch. 13',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved == true) {
      try {
        await Api.updateTopic(topic['id'] as String, {
          'name': nameController.text,
          'book_reference': bookController.text,
        });
        await _load();
      } catch (e) {
        _toast('Update failed: $e');
      }
    }
    nameController.dispose();
    bookController.dispose();
  }

  Future<void> _addTopic() async {
    final nameController = TextEditingController();
    final bookController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add topic'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Topic name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bookController,
                decoration: const InputDecoration(
                    labelText: 'Reference book (optional)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add')),
        ],
      ),
    );
    if (saved == true && nameController.text.trim().isNotEmpty) {
      try {
        await Api.createTopic(nameController.text, bookController.text);
        await _load();
      } catch (e) {
        _toast('Add failed: $e');
      }
    }
    nameController.dispose();
    bookController.dispose();
  }

  Future<void> _deleteTopic(Map<String, dynamic> topic) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${topic['name']}"?'),
        content: const Text(
            'This also deletes its challenges and PDF excerpts. Notes are kept but untagged.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await Api.deleteTopic(topic['id'] as String);
        await _load();
      } catch (e) {
        _toast('Delete failed: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    _sectionTitle('LLM provider'),
                    _llmSection(),
                    const SizedBox(height: 24),
                    _sectionTitle('Obsidian vault (GitHub)'),
                    _githubSection(),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _sectionTitle('Topics & reference books'),
                        TextButton.icon(
                          onPressed: _addTopic,
                          icon: const Icon(Icons.add),
                          label: const Text('Add topic'),
                        ),
                      ],
                    ),
                    _topicsSection(),
                    const SizedBox(height: 32),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.save),
                      label: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(_saving ? 'Saving...' : 'Save settings'),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child:
            Text(text, style: Theme.of(context).textTheme.titleLarge),
      );

  String _maskHint(String settingsKey, String label) {
    final masked = _settings[settingsKey] as String? ?? '';
    return masked.isEmpty
        ? 'Paste your $label (not set yet)'
        : 'Currently set: $masked — paste to replace';
  }

  Widget _llmSection() {
    final defaults =
        (_settings['default_models'] as Map<String, dynamic>?) ?? {};
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: const [
                DropdownMenuItem(
                    value: 'anthropic', child: Text('Anthropic (Claude)')),
                DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
              ],
              onChanged: (value) =>
                  setState(() => _provider = value ?? 'anthropic'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelController,
              decoration: InputDecoration(
                labelText: 'Model (blank = default)',
                hintText: 'default: ${defaults[_provider] ?? ''}',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _anthropicKeyController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Anthropic API key',
                hintText: _maskHint('anthropic_api_key_masked', 'Anthropic key'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _openaiKeyController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'OpenAI API key',
                hintText: _maskHint('openai_api_key_masked', 'OpenAI key'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Keys are written to the local .env file and used only by the local backend.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _githubSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _repoController,
              decoration: const InputDecoration(
                labelText: 'Obsidian vault repo URL',
                hintText: 'https://github.com/you/obsidian-vault',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _githubTokenController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'GitHub personal access token',
                hintText: _maskHint('github_token_masked', 'GitHub token'),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: _syncing ? null : _syncGithub,
                icon: _syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync),
                label: Text(_syncing ? 'Syncing...' : 'Sync vault now'),
              ),
            ),
            Text(
              'Save settings first if you changed the URL or token. Vault folders are '
              'matched to topics by name (e.g. a "Quantum Mechanics" folder).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _topicsSection() {
    if (_topics.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No topics yet — add one above.'),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          for (final topic in _topics.cast<Map<String, dynamic>>())
            ListTile(
              title: Text(topic['name'] as String? ?? '?'),
              subtitle: Text(
                (topic['book_reference'] as String? ?? '').isEmpty
                    ? 'No reference book set — tap to edit'
                    : 'Book: ${topic['book_reference']}\n'
                        'Next review: ${topic['next_review_date']} '
                        '(interval ${topic['interval_days']}d)',
              ),
              isThreeLine:
                  (topic['book_reference'] as String? ?? '').isNotEmpty,
              onTap: () => _editTopic(topic),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Upload reference PDF',
                    icon: const Icon(Icons.upload_file),
                    onPressed: () => _uploadPdf(topic),
                  ),
                  IconButton(
                    tooltip: 'Edit',
                    icon: const Icon(Icons.edit),
                    onPressed: () => _editTopic(topic),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteTopic(topic),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
