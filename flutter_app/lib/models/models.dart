// Calculator history row returned by backend.
class CalcHistoryItem {
  final int id;
  final String equation;
  final String result;
  final DateTime timestamp;

  CalcHistoryItem({
    required this.id,
    required this.equation,
    required this.result,
    required this.timestamp,
  });

  factory CalcHistoryItem.fromJson(Map<String, dynamic> json) {
    return CalcHistoryItem(
      id: json['id'],
      equation: json['equation'],
      result: json['result'],
      timestamp: DateTime.parse(json['timestamp']),
    );
  }
}

// Chat session metadata shown in sidebar/history.
class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
  });

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'],
      title: json['title'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }
}

// One message in a chat thread.
class ChatMessage {
  final int? id;
  final String role; // 'user' or 'assistant'
  final String content;
  final String? imageData;
  final DateTime timestamp;

  ChatMessage({
    this.id,
    required this.role,
    required this.content,
    this.imageData,
    required this.timestamp,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'],
      role: json['role'],
      content: json['content'] ?? '',
      imageData: json['imageData'],
      timestamp: DateTime.parse(json['timestamp']),
    );
  }

  bool get isUser => role == 'user';
}

class UsageStats {
  final int usedTokens;
  final int limitTokens;
  final int remainingTokens;
  final int windowHours;
  final double usagePercent;
  final int retryAfterSeconds;
  final bool unlimited;

  UsageStats({
    required this.usedTokens,
    required this.limitTokens,
    required this.remainingTokens,
    required this.windowHours,
    required this.usagePercent,
    required this.retryAfterSeconds,
    required this.unlimited,
  });

  factory UsageStats.fromJson(Map<String, dynamic> json) {
    return UsageStats(
      usedTokens: (json['usedTokens'] ?? 0) as int,
      limitTokens: (json['limitTokens'] ?? 0) as int,
      remainingTokens: (json['remainingTokens'] ?? 0) as int,
      windowHours: (json['windowHours'] ?? 5) as int,
      usagePercent: ((json['usagePercent'] ?? 0) as num).toDouble(),
      retryAfterSeconds: (json['retryAfterSeconds'] ?? 0) as int,
      unlimited: (json['unlimited'] ?? false) as bool,
    );
  }
}

// Signed-in user profile returned from auth endpoint.
class UserProfile {
  final String userId;
  final String email;
  final String name;
  final String? picture;
  final String accessToken;

  UserProfile({
    required this.userId,
    required this.email,
    required this.name,
    this.picture,
    required this.accessToken,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      userId: json['userId'],
      email: json['email'],
      name: json['name'],
      picture: json['picture'],
      accessToken: json['accessToken'],
    );
  }

  String get initials {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : 'U';
  }
}
