/*
 * Copyright 2023 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import SwiftProtobuf

@_implementationOnly import WebRTC

class Transport: MulticastDelegate<TransportDelegate> {
    typealias OnOfferBlock = (RTCSessionDescription) async throws -> Void

    // MARK: - Public

    public let target: Livekit_SignalTarget
    public let isPrimary: Bool

    public var isRestartingIce: Bool = false
    public var onOffer: OnOfferBlock?

    public var connectionState: RTCPeerConnectionState {
        DispatchQueue.liveKitWebRTC.sync { _pc.connectionState }
    }

    public var localDescription: RTCSessionDescription? {
        DispatchQueue.liveKitWebRTC.sync { _pc.localDescription }
    }

    public var remoteDescription: RTCSessionDescription? {
        DispatchQueue.liveKitWebRTC.sync { _pc.remoteDescription }
    }

    public var signalingState: RTCSignalingState {
        DispatchQueue.liveKitWebRTC.sync { _pc.signalingState }
    }

    public var isConnected: Bool {
        connectionState == .connected
    }

    // create debounce func
    public lazy var negotiate = Utils.createDebounceFunc(on: _queue,
                                                         wait: 0.1,
                                                         onCreateWorkItem: { [weak self] workItem in
                                                             self?._debounceWorkItem = workItem
                                                         }, fnc: { [weak self] in
                                                             Task { [weak self] in
                                                                 try await self?.createAndSendOffer()
                                                             }
                                                         })

    // MARK: - Private

    private let _queue = DispatchQueue(label: "LiveKitSDK.transport", qos: .default)

    private var _reNegotiate: Bool = false

    // forbid direct access to PeerConnection
    private let _pc: RTCPeerConnection
    private var _pendingCandidatesQueue = AsyncQueueActor<RTCIceCandidate>()

    // keep reference to cancel later
    private var _debounceWorkItem: DispatchWorkItem?

    init(config: RTCConfiguration,
         target: Livekit_SignalTarget,
         primary: Bool,
         delegate: TransportDelegate) throws
    {
        // try create peerConnection
        guard let pc = Engine.createPeerConnection(config,
                                                   constraints: .defaultPCConstraints)
        else {
            throw EngineError.webRTC(message: "failed to create peerConnection")
        }

        self.target = target
        isPrimary = primary
        _pc = pc

        super.init()
        log()

        DispatchQueue.liveKitWebRTC.sync { pc.delegate = self }
        add(delegate: delegate)
    }

    deinit {
        log()
    }

    func add(iceCandidate candidate: RTCIceCandidate) async throws {
        if remoteDescription != nil, !isRestartingIce {
            return try await _pc.add(candidate)
        }

        await _pendingCandidatesQueue.enqueue(candidate)
    }

    func set(remoteDescription sd: RTCSessionDescription) async throws {
        try await _pc.setRemoteDescription(sd)

        try await _pendingCandidatesQueue.resume { candidate in
            do {
                try await add(iceCandidate: candidate)
            } catch {
                log("Failed to add(iceCandidate:) with error: \(error)", .error)
            }
        }

        isRestartingIce = false

        if _reNegotiate {
            _reNegotiate = false
            try await createAndSendOffer()
        }
    }

    func createAndSendOffer(iceRestart: Bool = false) async throws {
        guard let onOffer else {
            log("onOffer is nil", .warning)
            return
        }

        var constraints = [String: String]()
        if iceRestart {
            log("Restarting ICE...")
            constraints[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue
            isRestartingIce = true
        }

        if signalingState == .haveLocalOffer, !(iceRestart && remoteDescription != nil) {
            _reNegotiate = true
            return
        }

        // Actually negotiate
        func _negotiateSequence() async throws {
            let offer = try await createOffer(for: constraints)
            try await _pc.setLocalDescription(offer)
            try await onOffer(offer)
        }

        if signalingState == .haveLocalOffer, iceRestart, let sd = remoteDescription {
            try await set(remoteDescription: sd)
            return try await _negotiateSequence()
        }

        try await _negotiateSequence()
    }

    func close() async {
        // prevent debounced negotiate firing
        _debounceWorkItem?.cancel()

        DispatchQueue.liveKitWebRTC.sync {
            // Stop listening to delegate
            self._pc.delegate = nil
            // Remove all senders (if any)
            for sender in self._pc.senders {
                self._pc.removeTrack(sender)
            }

            self._pc.close()
        }
    }
}

// MARK: - Stats

extension Transport {
    func statistics(for sender: RTCRtpSender) async -> RTCStatisticsReport {
        await _pc.statistics(for: sender)
    }

    func statistics(for receiver: RTCRtpReceiver) async -> RTCStatisticsReport {
        await _pc.statistics(for: receiver)
    }
}

// MARK: - RTCPeerConnectionDelegate

extension Transport: RTCPeerConnectionDelegate {
    func peerConnection(_: RTCPeerConnection, didChange state: RTCPeerConnectionState) {
        log("did update state \(state) for \(target)")
        notify { $0.transport(self, didUpdate: state) }
    }

    func peerConnection(_: RTCPeerConnection,
                        didGenerate candidate: RTCIceCandidate)
    {
        log("Did generate ice candidates \(candidate) for \(target)")
        notify { $0.transport(self, didGenerate: candidate) }
    }

    func peerConnectionShouldNegotiate(_: RTCPeerConnection) {
        log("ShouldNegotiate for \(target)")
        notify { $0.transportShouldNegotiate(self) }
    }

    func peerConnection(_: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream])
    {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("didAddTrack type: \(type(of: track)), id: \(track.trackId)")
        notify { $0.transport(self, didAddTrack: track, rtpReceiver: rtpReceiver, streams: mediaStreams) }
    }

    func peerConnection(_: RTCPeerConnection,
                        didRemove rtpReceiver: RTCRtpReceiver)
    {
        guard let track = rtpReceiver.track else {
            log("Track is empty for \(target)", .warning)
            return
        }

        log("didRemove track: \(track.trackId)")
        notify { $0.transport(self, didRemove: track) }
    }

    func peerConnection(_: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        log("Received data channel \(dataChannel.label) for \(target)")
        notify { $0.transport(self, didOpen: dataChannel) }
    }

    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceConnectionState) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
}

// MARK: - Private

private extension Transport {
    func createOffer(for constraints: [String: String]? = nil) async throws -> RTCSessionDescription {
        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await _pc.offer(for: mediaConstraints)
    }
}

// MARK: - Internal

extension Transport {
    func createAnswer(for constraints: [String: String]? = nil) async throws -> RTCSessionDescription {
        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints,
                                                     optionalConstraints: nil)

        return try await _pc.answer(for: mediaConstraints)
    }

    func set(localDescription sd: RTCSessionDescription) async throws {
        try await _pc.setLocalDescription(sd)
    }

    func addTransceiver(with track: RTCMediaStreamTrack,
                        transceiverInit: RTCRtpTransceiverInit) throws -> RTCRtpTransceiver
    {
        guard let transceiver = DispatchQueue.liveKitWebRTC.sync(execute: { _pc.addTransceiver(with: track, init: transceiverInit) }) else {
            throw EngineError.webRTC(message: "Failed to add transceiver")
        }

        return transceiver
    }

    func remove(track sender: RTCRtpSender) throws {
        guard DispatchQueue.liveKitWebRTC.sync(execute: { _pc.removeTrack(sender) }) else {
            throw EngineError.webRTC(message: "Failed to remove track")
        }
    }

    func dataChannel(for label: String,
                     configuration: RTCDataChannelConfiguration,
                     delegate: RTCDataChannelDelegate? = nil) -> RTCDataChannel?
    {
        let result = DispatchQueue.liveKitWebRTC.sync { _pc.dataChannel(forLabel: label, configuration: configuration) }
        result?.delegate = delegate
        return result
    }
}
