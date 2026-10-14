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
/// Holds the turn's content, role, and any alternate generations (swipes).
class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.name,
    this.isSystemNote = false,
    this.swipes = const <String>[],
    this.swipeIndex = 0,
  });

  final ChatRole role;
  final String content;

  /// Speaker name, when the backend is told who is talking.
  final String? name;

  /// True for injected notes (Author's Note, depth-injected lore) as opposed to
  /// a real turn.
  final bool isSystemNote;

  /// Alternative generations for this turn.
  final List<String> swipes;

  /// Index of the currently visible swipe in [swipes].
  final int swipeIndex;

  bool get hasSwipes => swipes.length > 1;
  bool get canSwipeLeft => swipeIndex > 0;
  bool get canSwipeRight => swipeIndex < swipes.length - 1;

  ChatMessage copyWith({
    String? content,
    String? name,
    bool? isSystemNote,
    List<String>? swipes,
    int? swipeIndex,
  }) {
    final List<String> nextSwipes = swipes ?? this.swipes;
    final int nextIndex = swipeIndex ?? this.swipeIndex;
    return ChatMessage(
      role: role,
      content: content ??
          (nextSwipes.isNotEmpty &&
                  nextIndex >= 0 &&
                  nextIndex < nextSwipes.length
              ? nextSwipes[nextIndex]
              : this.content),
      name: name ?? this.name,
      isSystemNote: isSystemNote ?? this.isSystemNote,
      swipes: nextSwipes,
      swipeIndex: nextIndex,
    );
  }

  ChatMessage withSwipeIndex(int index) {
    if (index < 0 || index >= swipes.length) return this;
    return copyWith(swipeIndex: index, content: swipes[index]);
  }

  ChatMessage withAddedSwipe(String newContent) {
    final List<String> list = List<String>.from(
      swipes.isEmpty && content.isNotEmpty ? <String>[content] : swipes,
    )..add(newContent);
    return copyWith(
      swipes: list,
      swipeIndex: list.length - 1,
      content: newContent,
    );
  }

  ChatMessage withDeletedSwipe(int index) {
    if (swipes.length <= 1 || index < 0 || index >= swipes.length) return this;
    final List<String> list = List<String>.from(swipes)..removeAt(index);
    final int nextIndex = swipeIndex >= list.length
        ? list.length - 1
        : (swipeIndex > index ? swipeIndex - 1 : swipeIndex);
    return copyWith(
      swipes: list,
      swipeIndex: nextIndex,
      content: list[nextIndex],
    );
  }

  /// Returns a copy of this message with the active swipe/content replaced.
  ChatMessage withEditedContent(String newContent) {
    if (swipes.isEmpty) {
      return copyWith(
        content: newContent,
        swipes: <String>[newContent],
        swipeIndex: 0,
      );
    }
    final List<String> list = List<String>.from(swipes);
    final int idx = swipeIndex.clamp(0, list.length - 1);
    list[idx] = newContent;
    return copyWith(
      content: newContent,
      swipes: list,
      swipeIndex: idx,
    );
  }

  /// Appends additional text to the active swipe/content.
  ChatMessage withAppendedContent(String additional) {
    return withEditedContent('$content$additional');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role.name,
        if (name != null) 'name': name,
        'content': content,
        if (isSystemNote) 'isSystemNote': true,
        if (swipes.isNotEmpty) 'swipes': swipes,
        if (swipeIndex > 0) 'swipeIndex': swipeIndex,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final String content =
        json['content'] is String ? json['content'] as String : '';
    final List<String> rawSwipes = <String>[
      if (json['swipes'] is List)
        for (final Object? s in json['swipes'] as List)
          if (s is String) s,
    ];
    final int rawIndex = json['swipeIndex'] is int
        ? json['swipeIndex'] as int
        : (json['swipe_id'] is int ? json['swipe_id'] as int : 0);

    final List<String> resolvedSwipes = rawSwipes.isNotEmpty
        ? rawSwipes
        : (content.isNotEmpty ? <String>[content] : const <String>[]);
    final int resolvedIndex =
        (rawIndex >= 0 && rawIndex < resolvedSwipes.length) ? rawIndex : 0;

    return ChatMessage(
      role: ChatRole.fromName(json['role']),
      content:
          resolvedSwipes.isNotEmpty ? resolvedSwipes[resolvedIndex] : content,
      name: json['name'] is String ? json['name'] as String : null,
      isSystemNote: json['isSystemNote'] == true,
      swipes: resolvedSwipes,
      swipeIndex: resolvedIndex,
    );
  }

  @override
  String toString() =>
      '${role.name}: ${content.length} chars${swipes.length > 1 ? ' (${swipeIndex + 1}/${swipes.length} swipes)' : ''}';
}
