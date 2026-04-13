import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/models.dart';

// Single API gateway used by all screens/providers.
// Keeps endpoint wiring and SSE parsing in one place.
class ApiService {
  // Change this to your backend URL.
  // Android emulator: http://10.0.2.2:8080
  // iOS simulator / physical device on same network: http://<your-machine-ip>:8080
  static const String _defaultBaseUrl = 'http://10.0.2.2:8080';
  static String baseUrl = _defaultBaseUrl;

  String? _accessToken;

  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  void setToken(String token) {
    _accessToken = token;
  }

  void clearToken() {
    _accessToken = null;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_accessToken != null) 'Authorization': 'Bearer $_accessToken',
      };

  // ─── Auth ─────────────────────────────────────────────

  Future<UserProfile> signInWithGoogle(String idToken) async {
    final res = await http
        .post(
          Uri.parse('$baseUrl/api/auth/google'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'idToken': idToken}),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('Sign-in failed: ${res.body}');
    return UserProfile.fromJson(jsonDecode(res.body));
  }

  /// Returns true if the current access token is still valid.
  Future<bool> validateToken() async {
    if (_accessToken == null) return false;
    try {
      final res = await http
          .get(
            Uri.parse('$baseUrl/api/calc/history'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      // Network unavailable — assume token is still valid to allow offline use
      return true;
    }
  }

  // ─── Calculator History ───────────────────────────────

  Future<List<CalcHistoryItem>> getCalcHistory({DateTime? date}) async {
    String url = '$baseUrl/api/calc/history';
    if (date != null) {
      url += '?date=${date.toIso8601String().split('T')[0]}';
    }
    final res = await http.get(Uri.parse(url), headers: _headers);
    if (res.statusCode != 200) throw Exception('Failed to fetch history');
    final List data = jsonDecode(res.body);
    return data.map((e) => CalcHistoryItem.fromJson(e)).toList();
  }

  Future<void> saveCalcHistory(String equation, String result) async {
    await http.post(
      Uri.parse('$baseUrl/api/calc/history'),
      headers: _headers,
      body: jsonEncode({'equation': equation, 'result': result}),
    );
  }

  Future<void> deleteCalcHistory(int id) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/api/calc/history/$id'),
      headers: _headers,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Failed to delete history item');
    }
  }

  // ─── Chat Sessions ────────────────────────────────────

  Future<List<ChatSession>> getSessions(
      {String? search, DateTime? date}) async {
    final params = <String, String>{};
    if (search != null && search.isNotEmpty) params['search'] = search;
    if (date != null) params['date'] = date.toIso8601String().split('T')[0];

    final uri =
        Uri.parse('$baseUrl/api/ai/sessions').replace(queryParameters: params);
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) throw Exception('Failed to fetch sessions');
    final List data = jsonDecode(res.body);
    return data.map((e) => ChatSession.fromJson(e)).toList();
  }

  Future<String> createSession({String? id, String? title}) async {
    final res = await http.post(
      Uri.parse('$baseUrl/api/ai/sessions'),
      headers: _headers,
      body: jsonEncode({'id': id, 'title': title ?? 'New Chat'}),
    );
    if (res.statusCode != 200) throw Exception('Failed to create session');
    return jsonDecode(res.body)['id'];
  }

  Future<void> renameSession(String id, String title) async {
    await http.patch(
      Uri.parse('$baseUrl/api/ai/sessions/$id'),
      headers: _headers,
      body: jsonEncode({'title': title}),
    );
  }

  Future<void> deleteSession(String id) async {
    await http.delete(Uri.parse('$baseUrl/api/ai/sessions/$id'),
        headers: _headers);
  }

  Future<List<ChatMessage>> getMessages(String sessionId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/ai/sessions/$sessionId/messages'),
      headers: _headers,
    );
    if (res.statusCode != 200) throw Exception('Failed to fetch messages');
    final List data = jsonDecode(res.body);
    return data.map((e) => ChatMessage.fromJson(e)).toList();
  }

  // ─── Image Gallery ───────────────────────────────────────

  /// Returns all messages containing images across all user sessions.
  Future<List<Map<String, dynamic>>> getImages() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/ai/images'),
      headers: _headers,
    );
    if (res.statusCode != 200) throw Exception('Failed to fetch images');
    final List data = jsonDecode(res.body);
    return data.cast<Map<String, dynamic>>();
  }

  Future<UsageStats> getUsageStats() async {
    final res = await http.get(
      Uri.parse('$baseUrl/api/ai/usage'),
      headers: _headers,
    );
    if (res.statusCode != 200) throw Exception('Failed to fetch usage stats');
    return UsageStats.fromJson(jsonDecode(res.body));
  }

  // ─── AI Chat – Streaming SSE ──────────────────────────
  //
  // The backend sends Server-Sent Events in this format:
  //   data: {"type":"meta","sessionId":"...","title":"..."}  ← once at start
  //   data: {"type":"token","content":"chunk text"}          ← per streamed word(s)
  //   data: {"type":"done"}                                  ← stream finished
  //
  // SSE events emitted by the backend:
  //   meta        → sessionId, optional title, provider (ollama|openai)
  //   token       → content chunk to append live
  //   title       → smart title pushed async after stream completes
  //   done        → stream finished

  Stream<ChatStreamEvent> streamChatMessage({
    required String message,
    required String? sessionId,
    String? imageData,
    String? imageMimeType,
    List<String>? imageDataList,
    List<String>? imageMimeTypeList,
    String responseMode = 'fast',
    List<Map<String, String>>? history,
  }) async* {
    final client = http.Client();
    try {
      final request = http.Request('POST', Uri.parse('$baseUrl/api/ai/chat'));
      request.headers.addAll({
        ..._headers,
        'Accept': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Accept-Encoding': 'identity',
      });
      request.body = jsonEncode({
        'message': message,
        'sessionId': sessionId,
        'imageData': imageData,
        'imageMimeType': imageMimeType,
        'imageDataList': imageDataList,
        'imageMimeTypeList': imageMimeTypeList,
        'responseMode': responseMode,
        'history': history,
      });

      final streamedResponse = await client.send(request);

      if (streamedResponse.statusCode != 200) {
        final body = await streamedResponse.stream.bytesToString();
        throw Exception(
            'Chat request failed (${streamedResponse.statusCode}): $body');
      }

      final eventBuffer = StringBuffer();

      await for (final chunk in streamedResponse.stream) {
        final text = utf8.decode(chunk, allowMalformed: true);
        eventBuffer.write(text);

        var buffered = eventBuffer.toString().replaceAll('\r\n', '\n');
        int separatorIdx;
        while ((separatorIdx = buffered.indexOf('\n\n')) != -1) {
          final rawEvent = buffered.substring(0, separatorIdx).trim();
          buffered = buffered.substring(separatorIdx + 2);
          if (rawEvent.isEmpty) continue;

          final lines = rawEvent.split('\n');
          final dataLines = <String>[];
          for (final l in lines) {
            final t = l.trim();
            if (t.startsWith('data:')) {
              dataLines.add(t.substring(5).trimLeft());
            }
          }
          if (dataLines.isEmpty) continue;

          var data = dataLines.join('\n').trim();
          while (data.startsWith('data:')) {
            data = data.substring(5).trimLeft();
          }

          if (data == '[DONE]') {
            yield const ChatStreamEvent.done();
            return;
          }

          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final type = json['type'] as String?;
            switch (type) {
              case 'meta':
                yield ChatStreamEvent.meta(
                  sessionId: json['sessionId'] as String? ?? '',
                  title: json['title'] as String?,
                  provider: json['provider'] as String? ?? 'openai',
                );
              case 'token':
                final content = json['content'] as String? ?? '';
                if (content.isNotEmpty) {
                  yield ChatStreamEvent.token(content);
                }
              case 'title':
                final t = json['title'] as String? ?? '';
                if (t.isNotEmpty) {
                  yield ChatStreamEvent.titleUpdate(t);
                }
              case 'done':
                yield const ChatStreamEvent.done();
                return;
            }
          } catch (_) {
            // malformed event — skip
          }
        }

        eventBuffer
          ..clear()
          ..write(buffered);
      }

      yield const ChatStreamEvent.done();
    } finally {
      client.close();
    }
  }
}

// ─── SSE Event Types ──────────────────────────────────────

sealed class ChatStreamEvent {
  const ChatStreamEvent();

  const factory ChatStreamEvent.meta({
    required String sessionId,
    String? title,
    String? provider,
  }) = ChatStreamMeta;

  const factory ChatStreamEvent.token(String content) = ChatStreamToken;

  /// Async title event — backend sends this after generating a smart title
  const factory ChatStreamEvent.titleUpdate(String title) =
      ChatStreamTitleUpdate;

  const factory ChatStreamEvent.done() = ChatStreamDone;
}

class ChatStreamMeta extends ChatStreamEvent {
  final String sessionId;
  final String? title;
  final String? provider; // "ollama" or "openai"
  const ChatStreamMeta({required this.sessionId, this.title, this.provider});
}

class ChatStreamToken extends ChatStreamEvent {
  final String content;
  const ChatStreamToken(this.content);
}

class ChatStreamTitleUpdate extends ChatStreamEvent {
  final String title;
  const ChatStreamTitleUpdate(this.title);
}

class ChatStreamDone extends ChatStreamEvent {
  const ChatStreamDone();
}
