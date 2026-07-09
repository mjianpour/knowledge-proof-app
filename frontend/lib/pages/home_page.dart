import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/heatmap.dart';
import 'challenge_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, Map<String, dynamic>> _dayData = {};
  int _totalChallenges = 0;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHeatmap();
  }

  Future<void> _loadHeatmap() async {
    setState(() => _loading = true);
    try {
      final data = await Api.heatmap();
      final days = (data['days'] as List<dynamic>).cast<Map<String, dynamic>>();
      final map = <String, Map<String, dynamic>>{};
      var total = 0;
      for (final day in days) {
        map[day['date'] as String] = day;
        total += day['count'] as int;
      }
      setState(() {
        _dayData = map;
        _totalChallenges = total;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _openChallenge() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ChallengePage()));
    _loadHeatmap(); // refresh the heatmap after completing challenges
  }

  Future<void> _openSettings() async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsPage()));
    _loadHeatmap();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Deep Dive Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                FilledButton.icon(
                  onPressed: _openChallenge,
                  icon: const Icon(Icons.psychology, size: 36),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28, horizontal: 16),
                    child: Text("Today's Challenge",
                        style: TextStyle(fontSize: 28)),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'One deep conceptual problem per day, from your own notes and books.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const Spacer(),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Progress — $_totalChallenges challenges in the past year',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 12),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  )
                else if (_error != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Icon(Icons.cloud_off),
                          const SizedBox(width: 12),
                          Expanded(child: Text('Heatmap unavailable: $_error')),
                          TextButton(
                              onPressed: _loadHeatmap,
                              child: const Text('Retry')),
                        ],
                      ),
                    ),
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Heatmap(dayData: _dayData),
                  ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
