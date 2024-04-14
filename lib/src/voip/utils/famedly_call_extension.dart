import 'package:collection/collection.dart';

import 'package:matrix/matrix.dart';
import 'package:matrix/src/voip/models/call_membership.dart';

extension FamedlyCallMemberEventsExtension on Room {
  /// a map of every users famedly call event, holds the memberships list
  /// returns sorted according to originTs (oldest to newest)
  Map<String, FamedlyCallMemberEvent> getFamedlyCallEvents() {
    final Map<String, FamedlyCallMemberEvent> mappedEvents = {};
    final famedlyCallMemberStates =
        states.tryGetMap<String, Event>(VoIPEventTypes.FamedlyCallMemberEvent);

    if (famedlyCallMemberStates == null) return {};
    final sortedEvents = famedlyCallMemberStates.values
        .sorted((a, b) => a.originServerTs.compareTo(b.originServerTs));

    for (final element in sortedEvents) {
      mappedEvents
          .addAll({element.senderId: FamedlyCallMemberEvent.fromJson(element)});
    }
    return mappedEvents;
  }

  /// extracts memberships list form a famedly call event and maps it to a userid
  /// returns sorted (oldest to newest)
  Map<String, List<CallMembership>> getCallMembershipsFromRoom() {
    final parsedMemberEvents = getFamedlyCallEvents();
    final Map<String, List<CallMembership>> memberships = {};
    for (final element in parsedMemberEvents.entries) {
      memberships.addAll({element.key: element.value.memberships});
    }
    return memberships;
  }

  /// returns a list of memberships in the room for `user`
  List<CallMembership> getCallMembershipsForUser(String userId) {
    final parsedMemberEvents = getCallMembershipsFromRoom();
    final mem = parsedMemberEvents.tryGet<List<CallMembership>>(userId);
    return mem ?? [];
  }

  /// returns the user count (not sessions, yet) for the group call with id: `groupCallId`.
  /// returns 0 if group call not found
  int groupCallParticipantCount(String groupCallId) {
    int participantCount = 0;
    // userid:membership
    final memberships = getCallMembershipsFromRoom();

    memberships.forEach((key, value) {
      for (final membership in value) {
        if (membership.callId == groupCallId && !membership.isExpired) {
          participantCount++;
        }
      }
    });

    return participantCount;
  }

  bool get hasActiveGroupCall {
    if (activeGroupCallIds.isNotEmpty) {
      return true;
    }
    return false;
  }

  /// list of active group call ids
  List<String> get activeGroupCallIds {
    final Set<String> ids = {};
    final memberships = getCallMembershipsFromRoom();

    memberships.forEach((key, value) {
      for (final mem in value) {
        if (!mem.isExpired) ids.add(mem.callId);
      }
    });
    return ids.toList();
  }

  /// passing no `CallMembership` removes it from the state event.
  Future<void> updateFamedlyCallMemberStateEvent(
      CallMembership callMembership) async {
    final ownMemberships = getCallMembershipsForUser(client.userID!);

    // do not bother removing other deviceId expired events because we have no
    // ownership over them
    ownMemberships
        .removeWhere((element) => client.deviceID! == element.deviceId);

    ownMemberships.removeWhere((e) => e == callMembership);

    ownMemberships.add(callMembership);

    final newContent = {
      'memberships': List.from(ownMemberships.map((e) => e.toJson()))
    };

    await setFamedlyCallMemberEvent(newContent);
  }

  Future<void> removeFamedlyCallMemberEvent(
    String groupCallId,
    String deviceId, {
    String? application = 'm.call',
    String? scope = 'm.room',
  }) async {
    final ownMemberships = getCallMembershipsForUser(client.userID!);

    ownMemberships.removeWhere((mem) =>
        mem.callId == groupCallId &&
        mem.deviceId == deviceId &&
        mem.application == application &&
        mem.scope == scope);

    final newContent = {
      'memberships': List.from(ownMemberships.map((e) => e.toJson()))
    };
    await setFamedlyCallMemberEvent(newContent);
  }

  Future<void> setFamedlyCallMemberEvent(Map<String, List> newContent) async {
    if (groupCallsEnabled) {
      await client.setRoomStateWithKey(
        id,
        VoIPEventTypes.FamedlyCallMemberEvent,
        client.userID!,
        newContent,
      );
    } else {
      Logs().w(
          '[VOIP] cannot send ${VoIPEventTypes.FamedlyCallMemberEvent} events in room: $id, fix your PLs');
    }
  }

  /// returns a list of memberships from a famedly call matrix event
  List<CallMembership> getCallMembershipsFromEvent(MatrixEvent event) {
    if (event.roomId != id) return [];
    return getCallMembershipsFromEventContent(
        event.content, event.senderId, event.roomId!);
  }

  /// returns a list of memberships from a famedly call matrix event
  List<CallMembership> getCallMembershipsFromEventContent(
      Map<String, Object?> content, String senderId, String roomId) {
    final mems = content.tryGetList<Map>('memberships');
    final callMems = <CallMembership>[];
    for (final m in mems ?? []) {
      final mem = CallMembership.fromJson(m, senderId, roomId);
      if (mem != null) callMems.add(mem);
    }
    return callMems;
  }
}

bool isValidMemEvent(Map<String, Object?> event) {
  if (event['call_id'] is String &&
      event['device_id'] is String &&
      event['expires_ts'] is num &&
      event['foci_active'] is List) {
    return true;
  } else {
    Logs()
        .w('[VOIP] FamedlyCallMemberEvent ignoring unclean membership $event');
    return false;
  }
}
