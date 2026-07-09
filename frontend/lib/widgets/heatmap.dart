import 'package:flutter/material.dart';

/// GitHub-style contribution heatmap for the past [days] days.
/// Shading intensity = number of challenges completed that day;
/// hovering a cell shows the date and the topics attempted.
class Heatmap extends StatelessWidget {
  const Heatmap({super.key, required this.dayData, this.days = 365});

  /// date (yyyy-MM-dd) -> map with 'count' (int) and 'topics' (list of strings)
  final Map<String, Map<String, dynamic>> dayData;
  final int days;

  static const double _cell = 13;
  static const double _gap = 3;
  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Color _color(BuildContext context, int count) {
    final scheme = Theme.of(context).colorScheme;
    if (count <= 0) return scheme.surfaceContainerHighest;
    final level = count >= 4 ? 4 : count;
    return Color.lerp(
        scheme.primaryContainer, scheme.primary, (level - 1) / 3)!;
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    var start = todayDate.subtract(Duration(days: days - 1));
    // Align to the Monday on/before the start so columns are whole weeks.
    start = start.subtract(Duration(days: start.weekday - 1));

    final weeks = <List<DateTime?>>[];
    var cursor = start;
    while (!cursor.isAfter(todayDate)) {
      final week = <DateTime?>[];
      for (var i = 0; i < 7; i++) {
        final day = cursor.add(Duration(days: i));
        week.add(day.isAfter(todayDate) ? null : day);
      }
      weeks.add(week);
      cursor = cursor.add(const Duration(days: 7));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true, // land on the most recent weeks
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _monthLabels(context, weeks),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final week in weeks)
                Padding(
                  padding: const EdgeInsets.only(right: _gap),
                  child: Column(
                    children: [
                      for (final day in week)
                        Padding(
                          padding: const EdgeInsets.only(bottom: _gap),
                          child: day == null
                              ? const SizedBox(width: _cell, height: _cell)
                              : _dayCell(context, day),
                        ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _legend(context),
        ],
      ),
    );
  }

  Widget _monthLabels(BuildContext context, List<List<DateTime?>> weeks) {
    final labels = <Widget>[];
    int? lastMonth;
    for (final week in weeks) {
      final first = week.firstWhere((d) => d != null, orElse: () => null);
      String text = '';
      if (first != null && first.month != lastMonth) {
        text = _monthNames[first.month - 1];
        lastMonth = first.month;
      }
      labels.add(SizedBox(
        width: _cell + _gap,
        child: Text(text,
            style: Theme.of(context).textTheme.labelSmall,
            overflow: TextOverflow.visible,
            softWrap: false),
      ));
    }
    return Row(children: labels);
  }

  Widget _dayCell(BuildContext context, DateTime day) {
    final data = dayData[_key(day)];
    final count = (data?['count'] as int?) ?? 0;
    final topics = (data?['topics'] as List<dynamic>?)?.cast<String>() ?? [];
    final label = count == 0
        ? '${_key(day)}\nNo challenges'
        : '${_key(day)}\n$count challenge${count == 1 ? '' : 's'}: ${topics.join(', ')}';
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 200),
      child: Container(
        width: _cell,
        height: _cell,
        decoration: BoxDecoration(
          color: _color(context, count),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }

  Widget _legend(BuildContext context) {
    return Row(
      children: [
        Text('Less ', style: Theme.of(context).textTheme.labelSmall),
        for (final count in [0, 1, 2, 3, 4])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1.5),
            child: Container(
              width: _cell,
              height: _cell,
              decoration: BoxDecoration(
                color: _color(context, count),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        Text(' More', style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}
