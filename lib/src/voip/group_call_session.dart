/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2021 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General License for more details.
 *
 *   You should have received a copy of the GNU Affero General License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:matrix/src/utils/crypto/crypto.dart';
import 'package:matrix/src/voip/models/call_membership.dart';
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:matrix/src/voip/models/voip_id.dart';
import 'package:matrix/src/voip/utils/stream_helper.dart';

/// Holds methods for managing a group call. This class is also responsible for
/// holding and managing the individual `CallSession`s in a group call.
class GroupCallSession {
  // Config

  final Client client;
  final VoIP voip;
  final Room room;

  /// is a list of backend to allow passing multiple backend in the future
  /// we use the first backend everywhere as of now
  final CallBackend backend;
  final String? application;
  final String? scope;

  GroupCallState state = GroupCallState.localCallFeedUninitialized;

  StreamSubscription<CallSession>? _callSubscription;

  CallParticipant? get activeSpeaker => _activeSpeaker;
  CallParticipant? _activeSpeaker;

  WrappedMediaStream? get localUserMediaStream => _localUserMediaStream;
  WrappedMediaStream? _localUserMediaStream;

  WrappedMediaStream? get localScreenshareStream => _localScreenshareStream;
  WrappedMediaStream? _localScreenshareStream;

  CallParticipant? get localParticipant => voip.localParticipant;

  /// participant:volume
  final Map<CallParticipant, double> _audioLevelsMap = {};
  final List<CallSession> _callSessions = [];

  List<CallParticipant> get participants => List.unmodifiable(_participants);
  final List<CallParticipant> _participants = [];

  List<WrappedMediaStream> get userMediaStreams =>
      List.unmodifiable(_userMediaStreams);
  final List<WrappedMediaStream> _userMediaStreams = [];

  List<WrappedMediaStream> get screenShareStreams =>
      List.unmodifiable(_screenshareStreams);
  final List<WrappedMediaStream> _screenshareStreams = [];

  late String groupCallId;

  Timer? _activeSpeakerLoopTimeout;
  Timer? _resendMemberStateEventTimer;
  Timer? _memberLeaveEncKeyRotateDebounceTimer;

  final CachedStreamController<GroupCallSession> onGroupCallFeedsChanged =
      CachedStreamController();

  final CachedStreamController<GroupCallState> onGroupCallState =
      CachedStreamController();

  final CachedStreamController<GroupCallEvent> onGroupCallEvent =
      CachedStreamController();

  final CachedStreamController<WrappedMediaStream> onStreamAdd =
      CachedStreamController();

  final CachedStreamController<WrappedMediaStream> onStreamRemoved =
      CachedStreamController();

  bool get isLivekitCall => backend is LiveKitBackend;

  /// toggle e2ee setup and key sharing
  final bool enableE2EE;

  GroupCallSession({
    String? groupCallId,
    required this.client,
    required this.room,
    required this.voip,
    required this.backend,
    required this.enableE2EE,
    this.application = 'm.call',
    this.scope = 'm.room',
  }) {
    this.groupCallId = groupCallId ?? genCallID();
  }

  String get avatarName =>
      _getUser().calcDisplayname(mxidLocalPartFallback: false);

  String? get displayName => _getUser().displayName;

  User _getUser() {
    return room.unsafeGetUserFromMemoryOrFallback(client.userID!);
  }

  void setState(GroupCallState newState) {
    state = newState;
    onGroupCallState.add(newState);
    onGroupCallEvent.add(GroupCallEvent.groupCallStateChanged);
  }

  List<WrappedMediaStream> getLocalStreams() {
    final feeds = <WrappedMediaStream>[];

    if (localUserMediaStream != null) {
      feeds.add(localUserMediaStream!);
    }

    if (localScreenshareStream != null) {
      feeds.add(localScreenshareStream!);
    }

    return feeds;
  }

  bool hasLocalParticipant() {
    return _participants.contains(localParticipant);
  }

  Future<MediaStream> _getUserMedia(CallType type) async {
    final mediaConstraints = {
      'audio': true,
      'video': type == CallType.kVideo
          ? {
              'mandatory': {
                'minWidth': '640',
                'minHeight': '480',
                'minFrameRate': '30',
              },
              'facingMode': 'user',
              'optional': [CallConstants.optionalAudioConfig],
            }
          : false,
    };
    try {
      return await voip.delegate.mediaDevices.getUserMedia(mediaConstraints);
    } catch (e) {
      setState(GroupCallState.localCallFeedUninitialized);
      rethrow;
    }
  }

  Future<MediaStream> _getDisplayMedia() async {
    final mediaConstraints = {
      'audio': false,
      'video': true,
    };
    try {
      return await voip.delegate.mediaDevices.getDisplayMedia(mediaConstraints);
    } catch (e, s) {
      Logs().e('[VOIP] _getDisplayMedia failed because,', e, s);
    }
    return Null as MediaStream;
  }

  /// Initializes the local user media stream.
  /// The media stream must be prepared before the group call enters.
  /// if you allow the user to configure their camera and such ahead of time,
  /// you can pass that `stream` on to this function.
  /// This allows you to configure the camera before joining the call without
  ///  having to reopen the stream and possibly losing settings.
  Future<WrappedMediaStream?> initLocalStream(
      {WrappedMediaStream? stream}) async {
    if (isLivekitCall) {
      Logs().i('Livekit group call: not starting local call feed.');
      return null;
    }
    if (state != GroupCallState.localCallFeedUninitialized) {
      throw Exception('Cannot initialize local call feed in the $state state.');
    }

    setState(GroupCallState.initializingLocalCallFeed);

    WrappedMediaStream localWrappedMediaStream;

    if (stream == null) {
      MediaStream stream;

      try {
        stream = await _getUserMedia(CallType.kVideo);
      } catch (error) {
        setState(GroupCallState.localCallFeedUninitialized);
        rethrow;
      }

      localWrappedMediaStream = WrappedMediaStream(
        stream: stream,
        participant: localParticipant!,
        room: room,
        client: client,
        purpose: SDPStreamMetadataPurpose.Usermedia,
        audioMuted: stream.getAudioTracks().isEmpty,
        videoMuted: stream.getVideoTracks().isEmpty,
        isWeb: voip.delegate.isWeb,
        isGroupCall: true,
        voip: voip,
      );
    } else {
      localWrappedMediaStream = stream;
    }

    _localUserMediaStream = localWrappedMediaStream;
    await addUserMediaStream(localWrappedMediaStream);

    setState(GroupCallState.localCallFeedInitialized);

    return localWrappedMediaStream;
  }

  Future<void> updateMediaDeviceForCalls() async {
    for (final call in _callSessions) {
      await call.updateMediaDeviceForCall();
    }
  }

  void updateLocalUsermediaStream(WrappedMediaStream stream) {
    if (localUserMediaStream != null) {
      final oldStream = localUserMediaStream!.stream;
      localUserMediaStream!.setNewStream(stream.stream!);
      // ignore: discarded_futures
      stopMediaStream(oldStream);
    }
  }

  /// enter the group call.
  Future<void> enter({WrappedMediaStream? stream}) async {
    if (!(state == GroupCallState.localCallFeedUninitialized ||
        state == GroupCallState.localCallFeedInitialized)) {
      throw Exception('Cannot enter call in the $state state');
    }

    if (state == GroupCallState.localCallFeedUninitialized) {
      await initLocalStream(stream: stream);
    }

    await sendMemberStateEvent();

    _activeSpeaker = null;

    setState(GroupCallState.entered);

    Logs().v('Entered group call $groupCallId');

    // Set up _participants for the members currently in the call.
    // Other members will be picked up by the RoomState.members event.

    await onMemberStateChanged();

    if (!isLivekitCall) {
      for (final call in _callSessions) {
        await onIncomingCall(call);
      }

      _callSubscription = voip.onIncomingCall.stream.listen(onIncomingCall);

      onActiveSpeakerLoop();
    }

    voip.currentGroupCID = VoipId(roomId: room.id, callId: groupCallId);

    await voip.delegate.handleNewGroupCall(this);
  }

  Future<void> dispose() async {
    if (localUserMediaStream != null) {
      await removeUserMediaStream(localUserMediaStream!);
      _localUserMediaStream = null;
    }

    if (localScreenshareStream != null) {
      await stopMediaStream(localScreenshareStream!.stream);
      await removeScreenshareStream(localScreenshareStream!);
      _localScreenshareStream = null;
    }

    await removeMemberStateEvent();

    // removeCall removes it from `_callSessions` later.
    final callsCopy = _callSessions.toList();

    for (final call in callsCopy) {
      await removeCall(call, CallErrorCode.userHangup);
    }

    _activeSpeaker = null;
    _activeSpeakerLoopTimeout?.cancel();
    await _callSubscription?.cancel();
  }

  Future<void> leave() async {
    await dispose();
    setState(GroupCallState.localCallFeedUninitialized);
    voip.currentGroupCID = null;
    _participants.clear();
    // only remove our own, to save requesting if we join again, yes the other side
    // will send it anyway but welp
    encryptionKeysMap.remove(localParticipant!);
    _currentLocalKeyIndex = 0;
    _latestLocalKeyIndex = 0;
    voip.groupCalls.remove(VoipId(roomId: room.id, callId: groupCallId));
    await voip.delegate.handleGroupCallEnded(this);
    _resendMemberStateEventTimer?.cancel();
    _memberLeaveEncKeyRotateDebounceTimer?.cancel();
    setState(GroupCallState.ended);
  }

  bool get isLocalVideoMuted {
    if (localUserMediaStream != null) {
      return localUserMediaStream!.isVideoMuted();
    }

    return true;
  }

  bool get isMicrophoneMuted {
    if (localUserMediaStream != null) {
      return localUserMediaStream!.isAudioMuted();
    }

    return true;
  }

  Future<bool> setMicrophoneMuted(bool muted) async {
    if (!await hasMediaDevice(voip.delegate, MediaInputKind.audioinput)) {
      return false;
    }

    if (localUserMediaStream != null) {
      localUserMediaStream!.setAudioMuted(muted);
      setTracksEnabled(localUserMediaStream!.stream!.getAudioTracks(), !muted);
    }

    for (final call in _callSessions) {
      await call.setMicrophoneMuted(muted);
    }

    onGroupCallEvent.add(GroupCallEvent.localMuteStateChanged);
    return true;
  }

  Future<bool> setLocalVideoMuted(bool muted) async {
    if (!await hasMediaDevice(voip.delegate, MediaInputKind.videoinput)) {
      return false;
    }

    if (localUserMediaStream != null) {
      localUserMediaStream!.setVideoMuted(muted);
      setTracksEnabled(localUserMediaStream!.stream!.getVideoTracks(), !muted);
    }

    for (final call in _callSessions) {
      await call.setLocalVideoMuted(muted);
    }

    onGroupCallEvent.add(GroupCallEvent.localMuteStateChanged);
    return true;
  }

  bool get screensharingEnabled => isScreensharing();

  Future<bool> setScreensharingEnabled(
    bool enabled,
    String desktopCapturerSourceId,
  ) async {
    if (enabled == isScreensharing()) {
      return enabled;
    }

    if (enabled) {
      try {
        Logs().v('Asking for screensharing permissions...');
        final stream = await _getDisplayMedia();
        for (final track in stream.getTracks()) {
          // screen sharing should only have 1 video track anyway, so this only
          // fires once
          track.onEnded = () async {
            await setScreensharingEnabled(false, '');
          };
        }
        Logs().v(
            'Screensharing permissions granted. Setting screensharing enabled on all calls');
        _localScreenshareStream = WrappedMediaStream(
          stream: stream,
          participant: localParticipant!,
          room: room,
          client: client,
          purpose: SDPStreamMetadataPurpose.Screenshare,
          audioMuted: stream.getAudioTracks().isEmpty,
          videoMuted: stream.getVideoTracks().isEmpty,
          isWeb: voip.delegate.isWeb,
          isGroupCall: true,
          voip: voip,
        );

        addScreenshareStream(localScreenshareStream!);

        onGroupCallEvent.add(GroupCallEvent.localScreenshareStateChanged);
        for (final call in _callSessions) {
          await call.addLocalStream(
              await localScreenshareStream!.stream!.clone(),
              localScreenshareStream!.purpose);
        }

        //await sendMemberStateEvent();

        return true;
      } catch (e, s) {
        Logs().e('[VOIP] Enabling screensharing error', e, s);
        onGroupCallEvent.add(GroupCallEvent.error);
        return false;
      }
    } else {
      for (final call in _callSessions) {
        await call.removeLocalStream(call.localScreenSharingStream!);
      }

      await stopMediaStream(localScreenshareStream?.stream);
      await removeScreenshareStream(localScreenshareStream!);
      _localScreenshareStream = null;
      //await sendMemberStateEvent();
      onGroupCallEvent.add(GroupCallEvent.localMuteStateChanged);
      return false;
    }
  }

  bool isScreensharing() {
    return localScreenshareStream != null;
  }

  Future<void> onIncomingCall(CallSession newCall) async {
    // The incoming calls may be for another room, which we will ignore.
    if (newCall.room.id != room.id) {
      return;
    }

    if (newCall.state != CallState.kRinging) {
      Logs().w('Incoming call no longer in ringing state. Ignoring.');
      return;
    }

    if (newCall.groupCallId == null || newCall.groupCallId != groupCallId) {
      Logs().v(
          'Incoming call with groupCallId ${newCall.groupCallId} ignored because it doesn\'t match the current group call');
      await newCall.reject();
      return;
    }

    if (isLivekitCall) {
      Logs()
          .i('Received incoming call whilst in signaling-only mode! Ignoring.');
      return;
    }

    final existingCall = getCallForParticipant(
      CallParticipant(
        userId: newCall.remoteUserId!,
        deviceId: newCall.remoteDeviceId,
        // sessionId: newCall.remoteSessionId,
      ),
    );

    if (existingCall != null && existingCall.callId == newCall.callId) {
      return;
    }

    Logs().v(
        'GroupCallSession: incoming call from: ${newCall.remoteUserId}${newCall.remoteDeviceId}${newCall.remotePartyId}');

    // Check if the user calling has an existing call and use this call instead.
    if (existingCall != null) {
      await replaceCall(existingCall, newCall);
    } else {
      await addCall(newCall);
    }

    await newCall.answerWithStreams(getLocalStreams());
  }

  Future<void> sendMemberStateEvent() async {
    await room.updateFamedlyCallMemberStateEvent(
      CallMembership(
        userId: client.userID!,
        roomId: room.id,
        callId: groupCallId,
        application: application,
        scope: scope,
        backend: backend,
        deviceId: client.deviceID!,
        expiresTs: DateTime.now()
            .add(CallTimeouts.expireTsBumpDuration)
            .millisecondsSinceEpoch,
        membershipId: voip.currentSessionId,
      ),
    );

    if (_resendMemberStateEventTimer != null) {
      _resendMemberStateEventTimer!.cancel();
    }
    _resendMemberStateEventTimer = Timer.periodic(
        CallTimeouts.updateExpireTsTimerDuration, ((timer) async {
      Logs().d('sendMemberStateEvent updating member event with timer');
      if (state != GroupCallState.ended ||
          state != GroupCallState.localCallFeedUninitialized) {
        await sendMemberStateEvent();
      } else {
        await removeMemberStateEvent();
      }
    }));
  }

  Future<void> removeMemberStateEvent() {
    if (_resendMemberStateEventTimer != null) {
      Logs().d('resend member event timer cancelled');
      _resendMemberStateEventTimer!.cancel();
      _resendMemberStateEventTimer = null;
    }
    return room.removeFamedlyCallMemberEvent(
      groupCallId,
      client.deviceID!,
      application: application,
      scope: scope,
    );
  }

  /// compltetely rebuilds the local _participants list
  Future<void> onMemberStateChanged() async {
    if (state != GroupCallState.entered) {
      Logs().d(
          '[VOIP] early return onMemberStateChanged, group call state is not Entered. Actual state: ${state.toString()} ');
      return;
    }

    // The member events may be received for another room, which we will ignore.
    final mems =
        room.getCallMembershipsFromRoom().values.expand((element) => element);
    final memsForCurrentGroupCall = mems.where((element) {
      return element.callId == groupCallId &&
          !element.isExpired &&
          element.application == application &&
          element.scope == scope &&
          element.roomId == room.id; // sanity checks
    }).toList();

    final ignoredMems =
        mems.where((element) => !memsForCurrentGroupCall.contains(element));

    for (final mem in ignoredMems) {
      Logs().w(
          '[VOIP] Ignored ${mem.userId}\'s mem event ${mem.toJson()} while updating _participants list for callId: $groupCallId, expiry status: ${mem.isExpired}');
    }

    final List<CallParticipant> newP = [];

    for (final mem in memsForCurrentGroupCall) {
      final rp = CallParticipant(
        userId: mem.userId,
        deviceId: mem.deviceId,
      );

      newP.add(rp);

      if (rp == localParticipant) continue;

      if (isLivekitCall) {
        Logs().w(
            '[VOIP] onMemberStateChanged deteceted livekit call, skipping native webrtc stuff for member update');
        continue;
      }

      if (state != GroupCallState.entered) {
        Logs().w(
            '[VOIP] onMemberStateChanged groupCall state is currently $state, skipping member update');
        continue;
      }

      // Only initiate a call with a participant who has a id that is lexicographically
      // less than your own. Otherwise, that user will call you.
      if (localParticipant!.id.compareTo(rp.id) > 0) {
        Logs().e('[VOIP] Waiting for ${rp.id} to send call invite.');
        continue;
      }

      final existingCall = getCallForParticipant(rp);
      if (existingCall != null) {
        if (existingCall.remoteSessionId != mem.membershipId) {
          await existingCall.hangup(reason: CallErrorCode.unknownError);
        } else {
          Logs().e(
              '[VOIP] onMemberStateChanged Not updating _participants list, already have a ongoing call with ${rp.id}');
          continue;
        }
      }

      final opts = CallOptions(
        callId: genCallID(),
        room: room,
        voip: voip,
        dir: CallDirection.kOutgoing,
        localPartyId: voip.currentSessionId,
        groupCallId: groupCallId,
        type: CallType.kVideo,
        iceServers: await voip.getIceServers(),
      );
      final newCall = voip.createNewCall(opts);

      /// both invitee userId and deviceId are set here because there can be
      /// multiple devices from same user in a call, so we specifiy who the
      /// invite is for
      ///
      /// MOVE TO CREATENEWCALL?
      newCall.remoteUserId = mem.userId;
      newCall.remoteDeviceId = mem.deviceId;
      // party id set to when answered
      newCall.remoteSessionId = mem.membershipId;

      await newCall.placeCallWithStreams(getLocalStreams());

      await addCall(newCall);
    }
    final newPcopy = List<CallParticipant>.from(newP);
    final oldPcopy = List<CallParticipant>.from(_participants);
    final anyJoined = newPcopy.where((element) => !oldPcopy.contains(element));
    final anyLeft = oldPcopy.where((element) => !newPcopy.contains(element));

    if (anyJoined.isNotEmpty || anyLeft.isNotEmpty) {
      if (anyJoined.isNotEmpty) {
        Logs().d('anyJoined: ${anyJoined.map((e) => e.id).toString()}');
        _participants.addAll(anyJoined);

        if (isLivekitCall && enableE2EE) {
          // ratcheting does not work on web, we just create a whole new key everywhere
          if (voip.enableSFUE2EEKeyRatcheting) {
            await _ratchetLocalParticipantKey(anyJoined.toList());
          } else {
            await makeNewSenderKey(true);
          }
        }
      }
      if (anyLeft.isNotEmpty) {
        Logs().d('anyLeft: ${anyLeft.map((e) => e.id).toString()}');

        for (final leftp in anyLeft) {
          _participants.remove(leftp);
        }

        if (isLivekitCall && enableE2EE) {
          encryptionKeysMap.removeWhere((key, value) => anyLeft.contains(key));

          // debounce it because people leave at the same time
          if (_memberLeaveEncKeyRotateDebounceTimer != null) {
            _memberLeaveEncKeyRotateDebounceTimer!.cancel();
          }
          _memberLeaveEncKeyRotateDebounceTimer =
              Timer(CallTimeouts.makeKeyDelay, () async {
            await makeNewSenderKey(true);
          });
        }
      }

      onGroupCallEvent.add(GroupCallEvent.participantsChanged);
      Logs().d(
          '[VOIP] onMemberStateChanged current list: ${_participants.map((e) => e.id).toString()}');
    }
  }

  CallSession? getCallForParticipant(CallParticipant participant) {
    return _callSessions.singleWhereOrNull((call) =>
        call.groupCallId == groupCallId &&
        CallParticipant(
              userId: call.remoteUserId!,
              deviceId: call.remoteDeviceId,
              //sessionId: call.remoteSessionId,
            ) ==
            participant);
  }

  Future<void> addCall(CallSession call) async {
    _callSessions.add(call);
    await initCall(call);
    onGroupCallEvent.add(GroupCallEvent.callsChanged);
  }

  Future<void> replaceCall(
      CallSession existingCall, CallSession replacementCall) async {
    final existingCallIndex =
        _callSessions.indexWhere((element) => element == existingCall);

    if (existingCallIndex == -1) {
      throw Exception('Couldn\'t find call to replace');
    }

    _callSessions.removeAt(existingCallIndex);
    _callSessions.add(replacementCall);

    await disposeCall(existingCall, CallErrorCode.replaced);
    await initCall(replacementCall);

    onGroupCallEvent.add(GroupCallEvent.callsChanged);
  }

  /// Removes a peer call from group calls.
  Future<void> removeCall(CallSession call, CallErrorCode hangupReason) async {
    await disposeCall(call, hangupReason);

    _callSessions.removeWhere((element) => call.callId == element.callId);

    onGroupCallEvent.add(GroupCallEvent.callsChanged);
  }

  /// init a peer call from group calls.
  Future<void> initCall(CallSession call) async {
    if (call.remoteUserId == null) {
      throw Exception(
          'Cannot init call without proper invitee user and device Id');
    }

    call.onCallStateChanged.stream.listen(((event) async {
      await onCallStateChanged(call, event);
    }));

    call.onCallReplaced.stream.listen((CallSession newCall) async {
      await replaceCall(call, newCall);
    });

    call.onCallStreamsChanged.stream.listen((call) async {
      await call.tryRemoveStopedStreams();
      await onStreamsChanged(call);
    });

    call.onCallHangupNotifierForGroupCalls.stream.listen((event) async {
      await onCallHangup(call);
    });

    call.onStreamAdd.stream.listen((stream) {
      if (!stream.isLocal()) {
        onStreamAdd.add(stream);
      }
    });

    call.onStreamRemoved.stream.listen((stream) {
      if (!stream.isLocal()) {
        onStreamRemoved.add(stream);
      }
    });
  }

  Future<void> disposeCall(CallSession call, CallErrorCode hangupReason) async {
    if (call.remoteUserId == null) {
      throw Exception(
          'Cannot init call without proper invitee user and device Id');
    }

    if (call.hangupReason == CallErrorCode.replaced) {
      return;
    }

    if (call.state != CallState.kEnded) {
      // no need to emit individual handleCallEnded on group calls
      // also prevents a loop of hangup and onCallHangupNotifierForGroupCalls
      await call.hangup(reason: hangupReason, shouldEmit: false);
    }

    final usermediaStream = getUserMediaStreamByParticipantId(CallParticipant(
      userId: call.remoteUserId!,
      deviceId: call.remoteDeviceId,
      // sessionId: call.remoteSessionId,
    ).id);

    if (usermediaStream != null) {
      await removeUserMediaStream(usermediaStream);
    }

    final screenshareStream =
        getScreenshareStreamByParticipantId(CallParticipant(
      userId: call.remoteUserId!,
      deviceId: call.remoteDeviceId,
      //  sessionId: call.remoteSessionId,
    ).id);

    if (screenshareStream != null) {
      await removeScreenshareStream(screenshareStream);
    }
  }

  Future<void> onStreamsChanged(CallSession call) async {
    if (call.remoteUserId == null) {
      throw Exception(
          'Cannot init call without proper invitee user and device Id');
    }

    final currentUserMediaStream =
        getUserMediaStreamByParticipantId(CallParticipant(
      userId: call.remoteUserId!,
      deviceId: call.remoteDeviceId,
      //sessionId: call.remoteSessionId,
    ).id);
    final remoteUsermediaStream = call.remoteUserMediaStream;
    final remoteStreamChanged = remoteUsermediaStream != currentUserMediaStream;

    if (remoteStreamChanged) {
      if (currentUserMediaStream == null && remoteUsermediaStream != null) {
        await addUserMediaStream(remoteUsermediaStream);
      } else if (currentUserMediaStream != null &&
          remoteUsermediaStream != null) {
        await replaceUserMediaStream(
            currentUserMediaStream, remoteUsermediaStream);
      } else if (currentUserMediaStream != null &&
          remoteUsermediaStream == null) {
        await removeUserMediaStream(currentUserMediaStream);
      }
    }

    final currentScreenshareStream =
        getScreenshareStreamByParticipantId(CallParticipant(
      userId: call.remoteUserId!,
      deviceId: call.remoteDeviceId,
      //  sessionId: call.remoteSessionId,
    ).id);
    final remoteScreensharingStream = call.remoteScreenSharingStream;
    final remoteScreenshareStreamChanged =
        remoteScreensharingStream != currentScreenshareStream;

    if (remoteScreenshareStreamChanged) {
      if (currentScreenshareStream == null &&
          remoteScreensharingStream != null) {
        addScreenshareStream(remoteScreensharingStream);
      } else if (currentScreenshareStream != null &&
          remoteScreensharingStream != null) {
        await replaceScreenshareStream(
            currentScreenshareStream, remoteScreensharingStream);
      } else if (currentScreenshareStream != null &&
          remoteScreensharingStream == null) {
        await removeScreenshareStream(currentScreenshareStream);
      }
    }

    onGroupCallFeedsChanged.add(this);
  }

  Future<void> onCallStateChanged(CallSession call, CallState state) async {
    final audioMuted = localUserMediaStream?.isAudioMuted() ?? true;
    if (call.localUserMediaStream != null &&
        call.isMicrophoneMuted != audioMuted) {
      await call.setMicrophoneMuted(audioMuted);
    }

    final videoMuted = localUserMediaStream?.isVideoMuted() ?? true;

    if (call.localUserMediaStream != null &&
        call.isLocalVideoMuted != videoMuted) {
      await call.setLocalVideoMuted(videoMuted);
    }
  }

  Future<void> onCallHangup(CallSession call) async {
    if (call.hangupReason == CallErrorCode.replaced) {
      return;
    }
    await onStreamsChanged(call);
    await removeCall(call, call.hangupReason!);
  }

  WrappedMediaStream? getUserMediaStreamByParticipantId(String participantId) {
    final stream = _userMediaStreams
        .where((stream) => stream.participant.id == participantId);
    if (stream.isNotEmpty) {
      return stream.first;
    }
    return null;
  }

  Future<void> addUserMediaStream(WrappedMediaStream stream) async {
    _userMediaStreams.add(stream);
    //callFeed.measureVolumeActivity(true);
    onStreamAdd.add(stream);
    onGroupCallEvent.add(GroupCallEvent.userMediaStreamsChanged);
  }

  Future<void> replaceUserMediaStream(WrappedMediaStream existingStream,
      WrappedMediaStream replacementStream) async {
    final streamIndex = _userMediaStreams.indexWhere(
        (stream) => stream.participant.id == existingStream.participant.id);

    if (streamIndex == -1) {
      throw Exception('Couldn\'t find user media stream to replace');
    }

    _userMediaStreams.replaceRange(streamIndex, 1, [replacementStream]);

    await existingStream.dispose();
    //replacementStream.measureVolumeActivity(true);
    onGroupCallEvent.add(GroupCallEvent.userMediaStreamsChanged);
  }

  Future<void> removeUserMediaStream(WrappedMediaStream stream) async {
    final streamIndex = _userMediaStreams.indexWhere(
        (element) => element.participant.id == stream.participant.id);

    if (streamIndex == -1) {
      throw Exception('Couldn\'t find user media stream to remove');
    }

    _userMediaStreams.removeWhere(
        (element) => element.participant.id == stream.participant.id);
    _audioLevelsMap.remove(stream.participant);
    onStreamRemoved.add(stream);

    if (stream.isLocal()) {
      await stopMediaStream(stream.stream);
    }

    onGroupCallEvent.add(GroupCallEvent.userMediaStreamsChanged);

    if (_activeSpeaker == stream.participant && _userMediaStreams.isNotEmpty) {
      _activeSpeaker = _userMediaStreams[0].participant;
      onGroupCallEvent.add(GroupCallEvent.activeSpeakerChanged);
    }
  }

  void onActiveSpeakerLoop() async {
    CallParticipant? nextActiveSpeaker;
    // idc about screen sharing atm.
    final userMediaStreamsCopyList =
        List<WrappedMediaStream>.from(_userMediaStreams);
    for (final stream in userMediaStreamsCopyList) {
      if (stream.participant == localParticipant && stream.pc == null) {
        continue;
      }

      final List<StatsReport> statsReport = await stream.pc!.getStats();
      statsReport
          .removeWhere((element) => !element.values.containsKey('audioLevel'));

      // https://www.w3.org/TR/webrtc-stats/#summary
      final otherPartyAudioLevel = statsReport
          .singleWhereOrNull((element) =>
              element.type == 'inbound-rtp' &&
              element.values['kind'] == 'audio')
          ?.values['audioLevel'];
      if (otherPartyAudioLevel != null) {
        _audioLevelsMap[stream.participant] = otherPartyAudioLevel;
      }

      // https://www.w3.org/TR/webrtc-stats/#dom-rtcstatstype-media-source
      // firefox does not seem to have this though. Works on chrome and android
      final ownAudioLevel = statsReport
          .singleWhereOrNull((element) =>
              element.type == 'media-source' &&
              element.values['kind'] == 'audio')
          ?.values['audioLevel'];
      if (localParticipant != null &&
          ownAudioLevel != null &&
          _audioLevelsMap[localParticipant] != ownAudioLevel) {
        _audioLevelsMap[localParticipant!] = ownAudioLevel;
      }
    }

    double maxAudioLevel = double.negativeInfinity;
    // TODO: we probably want a threshold here?
    _audioLevelsMap.forEach((key, value) {
      if (value > maxAudioLevel) {
        nextActiveSpeaker = key;
        maxAudioLevel = value;
      }
    });

    if (nextActiveSpeaker != null && _activeSpeaker != nextActiveSpeaker) {
      _activeSpeaker = nextActiveSpeaker;
      onGroupCallEvent.add(GroupCallEvent.activeSpeakerChanged);
    }
    _activeSpeakerLoopTimeout?.cancel();
    _activeSpeakerLoopTimeout =
        Timer(CallConstants.activeSpeakerInterval, onActiveSpeakerLoop);
  }

  WrappedMediaStream? getScreenshareStreamByParticipantId(
      String participantId) {
    final stream = _screenshareStreams
        .where((stream) => stream.participant.id == participantId);
    if (stream.isNotEmpty) {
      return stream.first;
    }
    return null;
  }

  void addScreenshareStream(WrappedMediaStream stream) {
    _screenshareStreams.add(stream);
    onStreamAdd.add(stream);
    onGroupCallEvent.add(GroupCallEvent.screenshareStreamsChanged);
  }

  Future<void> replaceScreenshareStream(WrappedMediaStream existingStream,
      WrappedMediaStream replacementStream) async {
    final streamIndex = _screenshareStreams.indexWhere(
        (stream) => stream.participant.id == existingStream.participant.id);

    if (streamIndex == -1) {
      throw Exception('Couldn\'t find screenshare stream to replace');
    }

    _screenshareStreams.replaceRange(streamIndex, 1, [replacementStream]);

    await existingStream.dispose();
    onGroupCallEvent.add(GroupCallEvent.screenshareStreamsChanged);
  }

  Future<void> removeScreenshareStream(WrappedMediaStream stream) async {
    final streamIndex = _screenshareStreams
        .indexWhere((stream) => stream.participant.id == stream.participant.id);

    if (streamIndex == -1) {
      throw Exception('Couldn\'t find screenshare stream to remove');
    }

    _screenshareStreams.removeWhere(
        (element) => element.participant.id == stream.participant.id);

    onStreamRemoved.add(stream);

    if (stream.isLocal()) {
      await stopMediaStream(stream.stream);
    }

    onGroupCallEvent.add(GroupCallEvent.screenshareStreamsChanged);
  }

  /// participant:keyIndex:keyBin
  Map<CallParticipant, Map<int, Uint8List>> encryptionKeysMap = {};

  List<Future> setNewKeyTimeouts = [];

  Map<int, Uint8List>? getKeysForParticipant(CallParticipant participant) {
    return encryptionKeysMap[participant];
  }

  int indexCounter = 0;

  /// always chooses the next possible index, we cycle after 16 because
  /// no real adv with infinite list
  int getNewEncryptionKeyIndex() {
    final newIndex = indexCounter % 16;
    indexCounter++;
    return newIndex;
  }

  /// makes a new e2ee key for local user and sets it with a delay if specified
  /// used on first join and when someone leaves
  ///
  /// also does the sending for you
  Future<void> makeNewSenderKey(bool delayBeforeUsingKeyOurself) async {
    final key = secureRandomBytes(32);
    final keyIndex = getNewEncryptionKeyIndex();
    Logs().i('[VOIP E2EE] Generated new key $key at index $keyIndex');

    await _setEncryptionKey(
      localParticipant!,
      keyIndex,
      key,
      delayBeforeUsingKeyOurself: delayBeforeUsingKeyOurself,
      send: true,
    );
  }

  /// also does the sending for you
  Future<void> _ratchetLocalParticipantKey(List<CallParticipant> sendTo) async {
    final keyProvider = voip.delegate.keyProvider;

    if (keyProvider == null) {
      throw Exception('[VOIP] _ratchetKey called but KeyProvider was null');
    }

    final myKeys = encryptionKeysMap[localParticipant];

    if (myKeys == null || myKeys.isEmpty) {
      await makeNewSenderKey(false);
      return;
    }

    Uint8List? ratchetedKey;

    while (ratchetedKey == null || ratchetedKey.isEmpty) {
      Logs().i('[VOIP E2EE] Ignoring empty ratcheted key');
      ratchetedKey = await keyProvider.onRatchetKey(
          localParticipant!, latestLocalKeyIndex);
    }

    Logs().i(
        '[VOIP E2EE] Ratched latest key to $ratchetedKey at idx $latestLocalKeyIndex');

    await _setEncryptionKey(
      localParticipant!,
      latestLocalKeyIndex,
      ratchetedKey,
      delayBeforeUsingKeyOurself: false,
      send: true,
      sendTo: sendTo,
    );
  }

  /// used to send the key again incase someone `onCallEncryptionKeyRequest` but don't just send
  /// the last one because you also cycle back in your window which means you
  /// could potentially end up sharing a past key
  int get latestLocalKeyIndex => _latestLocalKeyIndex;
  int _latestLocalKeyIndex = 0;

  /// the key currently being used by the local cryptor, can possibly not be the latest
  /// key, check `latestLocalKeyIndex` for latest key
  int get currentLocalKeyIndex => _currentLocalKeyIndex;
  int _currentLocalKeyIndex = 0;

  /// sets incoming keys and also sends the key if it was for the local user
  /// if sendTo is null, its sent to all _participants, see `_sendEncryptionKeysEvent`
  Future<void> _setEncryptionKey(
    CallParticipant participant,
    int encryptionKeyIndex,
    Uint8List encryptionKeyBin, {
    bool delayBeforeUsingKeyOurself = false,
    bool send = false,
    List<CallParticipant>? sendTo,
  }) async {
    final encryptionKeys = encryptionKeysMap[participant] ?? <int, Uint8List>{};

    // if (encryptionKeys[encryptionKeyIndex] != null &&
    //     listEquals(encryptionKeys[encryptionKeyIndex]!, keyBin)) {
    //   Logs().i('[VOIP E2EE] Ignoring duplicate key');
    //   return;
    // }

    encryptionKeys[encryptionKeyIndex] = encryptionKeyBin;
    encryptionKeysMap[participant] = encryptionKeys;
    if (participant == localParticipant) {
      _latestLocalKeyIndex = encryptionKeyIndex;
    }

    if (send) {
      await _sendEncryptionKeysEvent(encryptionKeyIndex, sendTo: sendTo);
    }

    if (delayBeforeUsingKeyOurself) {
      // now wait for the key to propogate and then set it, hopefully users can
      // stil decrypt everything
      final useKeyTimeout = Future.delayed(CallTimeouts.useKeyDelay, () async {
        Logs().i(
            '[VOIP E2EE] setting key changed event for ${participant.id} idx $encryptionKeyIndex key $encryptionKeyBin');
        await voip.delegate.keyProvider?.onSetEncryptionKey(
            participant, encryptionKeyBin, encryptionKeyIndex);
        if (participant == localParticipant) {
          _currentLocalKeyIndex = encryptionKeyIndex;
        }
      });
      setNewKeyTimeouts.add(useKeyTimeout);
    } else {
      Logs().i(
          '[VOIP E2EE] setting key changed event for ${participant.id} idx $encryptionKeyIndex key $encryptionKeyBin');
      await voip.delegate.keyProvider?.onSetEncryptionKey(
          participant, encryptionKeyBin, encryptionKeyIndex);
      if (participant == localParticipant) {
        _currentLocalKeyIndex = encryptionKeyIndex;
      }
    }
  }

  /// sends the enc key to the devices using todevice, passing a list of
  /// sendTo only sends events to them
  /// setting keyIndex to null will send the latestKey
  Future<void> _sendEncryptionKeysEvent(int keyIndex,
      {List<CallParticipant>? sendTo}) async {
    Logs().i('Sending encryption keys event');

    final myKeys = getKeysForParticipant(localParticipant!);
    final myLatestKey = myKeys?[keyIndex];

    final sendKeysTo =
        sendTo ?? _participants.where((p) => p != localParticipant);

    if (myKeys == null || myLatestKey == null) {
      Logs().w(
          '[VOIP E2EE] _sendEncryptionKeysEvent Tried to send encryption keys event but no keys found!');
      await makeNewSenderKey(false);
      await _sendEncryptionKeysEvent(
        keyIndex,
        sendTo: sendTo,
      );
      return;
    }

    try {
      final keyContent = EncryptionKeysEventContent(
        [EncryptionKeyEntry(keyIndex, base64Encode(myLatestKey))],
        groupCallId,
      );
      final Map<String, Object> data = {
        ...keyContent.toJson(),
        // used to find group call in groupCalls when ToDeviceEvent happens,
        // plays nicely with backwards compatibility for mesh calls
        'conf_id': groupCallId,
        'device_id': client.deviceID!,
        'room_id': room.id,
      };
      await _sendToDeviceEvent(
        sendTo ?? sendKeysTo.toList(),
        data,
        VoIPEventTypes.EncryptionKeysEvent,
      );
    } catch (e, s) {
      Logs().e('Failed to send e2ee keys, retrying', e, s);
      await _sendEncryptionKeysEvent(
        keyIndex,
        sendTo: sendTo,
      );
    }
  }

  Future<void> onCallEncryption(Room room, String userId, String deviceId,
      Map<String, dynamic> content) async {
    if (!enableE2EE) {
      Logs().w('[VOIP] got sframe key but we do not support e2ee');
      return;
    }
    final keyContent = EncryptionKeysEventContent.fromJson(content);

    final callId = keyContent.callId;

    if (keyContent.keys.isEmpty) {
      Logs().w(
          '[VOIP E2EE] Received m.call.encryption_keys where keys is empty: callId=$callId');
      return;
    } else {
      Logs().i(
          '[VOIP E2EE]: onCallEncryption, got keys from $userId:$deviceId ${keyContent.toJson()}');
    }

    for (final key in keyContent.keys) {
      final encryptionKey = key.key;
      final encryptionKeyIndex = key.index;
      await _setEncryptionKey(
        CallParticipant(userId: userId, deviceId: deviceId),
        encryptionKeyIndex,
        base64Decode(
            encryptionKey), // base64Decode here because we receive base64Encoded version
        delayBeforeUsingKeyOurself: false,
        send: false,
      );
    }
  }

  Future<void> requestEncrytionKey(
      List<CallParticipant> remoteParticipants) async {
    final Map<String, Object> data = {
      'conf_id': groupCallId,
      'device_id': client.deviceID!,
      'room_id': room.id,
    };

    await _sendToDeviceEvent(
      remoteParticipants,
      data,
      VoIPEventTypes.RequestEncryptionKeysEvent,
    );
  }

  Future<void> onCallEncryptionKeyRequest(Room room, String userId,
      String deviceId, Map<String, dynamic> content) async {
    if (room.id != room.id) return;
    if (!enableE2EE) {
      Logs().w('[VOIP] got sframe key request but we do not support e2ee');
      return;
    }
    final mems = room.getCallMembershipsForUser(userId);
    if (mems
        .where((mem) =>
            mem.callId == groupCallId &&
            mem.userId == userId &&
            mem.deviceId == deviceId &&
            !mem.isExpired &&
            // sanity checks
            mem.backend.type == backend.type &&
            mem.roomId == room.id &&
            mem.application == application)
        .isNotEmpty) {
      Logs().d(
          '[VOIP] onCallEncryptionKeyRequest: request checks out, sending key on index: $latestLocalKeyIndex to $userId:$deviceId');
      await _sendEncryptionKeysEvent(
        latestLocalKeyIndex,
        sendTo: [CallParticipant(userId: userId, deviceId: deviceId)],
      );
    }
  }

  Future<void> _sendToDeviceEvent(List<CallParticipant> remoteParticipants,
      Map<String, Object> data, String eventType) async {
    Logs().v(
        '[VOIP] _sendToDeviceEvent: sending ${data.toString()} to ${remoteParticipants.map((e) => e.id)} ');
    final txid = VoIP.customTxid ?? client.generateUniqueTransactionId();
    final mustEncrypt = room.encrypted && client.encryptionEnabled;

    // could just combine the two but do not want to rewrite the enc thingy
    // wrappers here again.
    final List<DeviceKeys> mustEncryptkeysToSendTo = [];
    final Map<String, Map<String, Map<String, Object>>> unencryptedDataToSend =
        {};

    for (final participant in remoteParticipants) {
      if (participant.deviceId == null) continue;
      if (mustEncrypt) {
        await client.userDeviceKeysLoading;
        final deviceKey = client.userDeviceKeys[participant.userId]
            ?.deviceKeys[participant.deviceId];
        if (deviceKey != null) {
          mustEncryptkeysToSendTo.add(deviceKey);
        }
      } else {
        unencryptedDataToSend.addAll({
          participant.userId: {participant.deviceId!: data}
        });
      }
    }

    // prepped data, now we send
    if (mustEncrypt) {
      await client.sendToDeviceEncrypted(
          mustEncryptkeysToSendTo, eventType, data);
    } else {
      await client.sendToDevice(
        eventType,
        txid,
        unencryptedDataToSend,
      );
    }
  }
}