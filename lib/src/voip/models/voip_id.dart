class VoipId {
  final String roomId;
  final String callId;

  factory VoipId.fromId(String id) {
    final int lastIndex = id.lastIndexOf(':');
    return VoipId(
      roomId: id.substring(0, lastIndex),
      callId: id.substring(lastIndex + 1),
    );
  }

  VoipId({required this.roomId, required this.callId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VoipId && roomId == other.roomId && callId == other.callId;

  @override
  int get hashCode => roomId.hashCode ^ callId.hashCode;
}
