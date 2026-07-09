import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thin client for the local FastAPI backend. The backend holds all secrets;
/// this app only ever talks to localhost.
class Api {
  static const String base = 'http://localhost:8000/api';

  static Future<dynamic> _handle(http.Response response) async {
    final body = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }
    final detail = (body is Map && body['detail'] != null)
        ? body['detail'].toString()
        : 'HTTP ${response.statusCode}';
    throw ApiException(detail);
  }

  static Future<dynamic> _get(String path) async =>
      _handle(await http.get(Uri.parse('$base$path')));

  static Future<dynamic> _send(String method, String path,
      [Map<String, dynamic>? body]) async {
    final request = http.Request(method, Uri.parse('$base$path'));
    request.headers['Content-Type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final streamed = await request.send();
    return _handle(await http.Response.fromStream(streamed));
  }

  // Settings
  static Future<Map<String, dynamic>> getSettings() async =>
      (await _get('/settings')) as Map<String, dynamic>;

  static Future<Map<String, dynamic>> updateSettings(
          Map<String, dynamic> updates) async =>
      (await _send('PUT', '/settings', updates)) as Map<String, dynamic>;

  // Topics
  static Future<List<dynamic>> listTopics() async =>
      (await _get('/topics')) as List<dynamic>;

  static Future<void> createTopic(String name, String bookReference) =>
      _send('POST', '/topics', {'name': name, 'book_reference': bookReference});

  static Future<void> updateTopic(String id, Map<String, dynamic> updates) =>
      _send('PATCH', '/topics/$id', updates);

  static Future<void> deleteTopic(String id) => _send('DELETE', '/topics/$id');

  // Knowledge sources
  static Future<Map<String, dynamic>> syncGithub() async =>
      (await _send('POST', '/sync/github')) as Map<String, dynamic>;

  static Future<Map<String, dynamic>> uploadPdf(
      String topicId, String filename, Uint8List bytes) async {
    final request =
        http.MultipartRequest('POST', Uri.parse('$base/pdfs/upload'));
    request.fields['topic_id'] = topicId;
    request.files
        .add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await request.send();
    return (await _handle(await http.Response.fromStream(streamed)))
        as Map<String, dynamic>;
  }

  // Challenges
  static Future<List<dynamic>> listChallenges() async =>
      (await _get('/challenges')) as List<dynamic>;

  static Future<Map<String, dynamic>> startSession(
          int count, List<String> topicIds) async =>
      (await _send('POST', '/challenges/session',
          {'count': count, 'topic_ids': topicIds})) as Map<String, dynamic>;

  static Future<Map<String, dynamic>> todaysChallenge() async =>
      (await _send('POST', '/challenges/today')) as Map<String, dynamic>;

  static Future<Map<String, dynamic>> answerChallenge(
          String id, String answer) async =>
      (await _send('POST', '/challenges/$id/answer', {'answer': answer}))
          as Map<String, dynamic>;

  // Heatmap
  static Future<Map<String, dynamic>> heatmap() async =>
      (await _get('/heatmap')) as Map<String, dynamic>;

  // Live progress log (polled while loading)
  static Future<Map<String, dynamic>> progress() async =>
      (await _get('/progress')) as Map<String, dynamic>;
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}
