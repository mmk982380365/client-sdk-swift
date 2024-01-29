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

@_implementationOnly import WebRTC

extension Engine: TransportDelegate {
    func transport(_ transport: Transport, didUpdate pcState: RTCPeerConnectionState) {
        log("target: \(transport.target), state: \(pcState)")

        // primary connected
        if transport.isPrimary, case .connected = pcState {
            primaryTransportConnectedCompleter.resume(returning: ())
        }

        // publisher connected
        if case .publisher = transport.target, case .connected = pcState {
            publisherTransportConnectedCompleter.resume(returning: ())
        }

        if _state.connectionState.isConnected {
            // Attempt re-connect if primary or publisher transport failed
            if transport.isPrimary || (_state.hasPublished && transport.target == .publisher), [.disconnected, .failed].contains(pcState) {
                log("[reconnect] starting, reason: transport disconnected or failed")
                Task {
                    try await startReconnect()
                }
            }
        }
    }

    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate) {
        log("didGenerate iceCandidate")
        Task {
            try await signalClient.sendCandidate(candidate: iceCandidate, target: transport.target)
        }
    }

    func transport(_ transport: Transport, didAddTrack track: RTCMediaStreamTrack, rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        log("did add track")
        if transport.target == .subscriber {
            // execute block when connected
            execute(when: { state, _ in state.connectionState == .connected },
                    // always remove this block when disconnected
                    removeWhen: { state, _ in state.connectionState == .disconnected() })
            { [weak self] in
                guard let self else { return }
                self.notify { $0.engine(self, didAddTrack: track, rtpReceiver: rtpReceiver, streams: streams) }
            }
        }
    }

    func transport(_ transport: Transport, didRemove track: RTCMediaStreamTrack) {
        if transport.target == .subscriber {
            notify { $0.engine(self, didRemove: track) }
        }
    }

    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {
        log("Server opened data channel \(dataChannel.label)(\(dataChannel.readyState))")

        Task {
            if subscriberPrimary, transport.target == .subscriber {
                switch dataChannel.label {
                case RTCDataChannel.labels.reliable: await subscriberDataChannel.set(reliable: dataChannel)
                case RTCDataChannel.labels.lossy: await subscriberDataChannel.set(lossy: dataChannel)
                default: log("Unknown data channel label \(dataChannel.label)", .warning)
                }
            }
        }
    }

    func transportShouldNegotiate(_: Transport) {}
}
