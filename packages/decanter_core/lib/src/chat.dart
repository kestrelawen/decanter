/// Who authored a message.
enum ChatRole {
  system,
  user,
  assistant;

  static ChatRole fromName(Object? name) {
    for (final r in ChatRole.values) {
      if (r.name == name) return r;
    }
    return ChatRole.system;
  }
}

/// One turn of a chat.
///
/// Deliberately narrower than SillyTavern's stored message shape: this is only
/// what prompt assembly and lorebook scanning need. Presentation metadata
/// (swipes, timestamps, generation parameters) lives elsewhere.
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.name,
    this.isSystemNote = false,
  });

  final ChatRole role;
  final String content;

  /// Speaker name, when the backend is told who is talking.
  final String? name;

  /// True for injected notes (Author's Note, depth-injected lore) as opposed to
  /// a real turn.
  final bool isSystemNote;

  ChatMessage copyWith({String? content}) => ChatMessage(
        role: role,
        content: content ?? this.content,
        name: name,
        isSystemNote: isSystemNote,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role.name,
        if (name != null) 'name': name,
        'content': content,
        if (isSystemNote) 'isSystemNote': true,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: ChatRole.fromName(json['role']),
        content: json['content'] is String ? json['content'] as String : '',
        name: json['name'] is String ? json['name'] as String : null,
        isSystemNote: json['isSystemNote'] == true,
      );

  @override
  String toString() => '${role.name}: ${content.length} chars';
}
