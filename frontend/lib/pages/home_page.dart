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
  int _dailyTarget = 1;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadHeatmap();
    _loadDailyTarget();
  }

  Future<void> _loadDailyTarget() async {
    try {
      final settings = await Api.getSettings();
      final target = settings['daily_target'] as int? ?? 1;
      setState(() => _dailyTarget = target.clamp(1, 37));
    } catch (_) {
      // Backend not configured yet — keep the default of 1.
    }
  }

  Future<void> _saveDailyTarget(int value) async {
    try {
      await Api.updateSettings({'daily_target': value});
    } catch (_) {
      // Non-fatal: the session still uses the slider value locally.
    }
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
    final target = _dailyTarget; // read live at click time
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChallengePage(target: target)));
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
                  icon: const Icon(Icons.psychology),
                  label: const Text("Today's Challenge"),
                ),
                const SizedBox(height: 12),
                Text(
                  _dailyTarget == 1
                      ? 'One deep conceptual problem per day, from your own notes and books.'
                      : '$_dailyTarget deep conceptual problems today, from your own notes and books.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 20),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Row(
                    children: [
                      Text('Questions today',
                          style: Theme.of(context).textTheme.labelLarge),
                      Expanded(
                        child: Slider(
                          value: _dailyTarget.toDouble(),
                          min: 1,
                          max: 37,
                          divisions: 36,
                          label: '$_dailyTarget',
                          onChanged: (value) =>
                              setState(() => _dailyTarget = value.round()),
                          onChangeEnd: (value) =>
                              _saveDailyTarget(value.round()),
                        ),
                      ),
                      SizedBox(
                        width: 28,
                        child: Text('$_dailyTarget',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                    ],
                  ),
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
