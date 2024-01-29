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

actor DataChannelPairActor: NSObject, Loggable {
    // MARK: - Types

    public typealias OnDataPacket = (_ dataPacket: Livekit_DataPacket) -> Void

    // MARK: - Public

    public let openCompleter = AsyncCompleter<Void>(label: "Data channel open", timeOut: .defaultPublisherDataChannelOpen)

    public var isOpen: Bool {
        guard let reliable = _reliableChannel, let lossy = _lossyChannel else { return false }
        return reliable.readyState == .open && lossy.readyState == .open
    }

    // MARK: - Private

    private let _onDataPacket: OnDataPacket?
    private var _reliableChannel: RTCDataChannel?
    private var _lossyChannel: RTCDataChannel?

    public init(reliableChannel: RTCDataChannel? = nil,
                lossyChannel: RTCDataChannel? = nil,
                onDataPacket: OnDataPacket? = nil)
    {
        _reliableChannel = reliableChannel
        _lossyChannel = lossyChannel
        _onDataPacket = onDataPacket
    }

    public func set(reliable channel: RTCDataChannel?) {
        _reliableChannel = channel
        channel?.delegate = self

        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    public func set(lossy channel: RTCDataChannel?) {
        _lossyChannel = channel
        channel?.delegate = self

        if isOpen {
            openCompleter.resume(returning: ())
        }
    }

    public func reset() {
        _reliableChannel?.close()
        _lossyChannel?.close()
        _reliableChannel = nil
        _lossyChannel = nil

        openCompleter.reset()
    }

    public func send(userPacket: Livekit_UserPacket, reliability: Reliability) throws {
        guard isOpen else {
            throw InternalError.state(message: "Data channel is not open")
        }

        let packet = Livekit_DataPacket.with {
            $0.kind = reliability.toPBType()
            $0.user = userPacket
        }

        let serializedData = try packet.serializedData()
        let rtcData = Engine.createDataBuffer(data: serializedData)

        let channel = (reliability == .reliable) ? _reliableChannel : _lossyChannel
        guard let sendDataResult = channel?.sendData(rtcData), sendDataResult else {
            throw InternalError.state(message: "sendData failed")
        }
    }

    public func infos() -> [Livekit_DataChannelInfo] {
        [_lossyChannel, _reliableChannel]
            .compactMap { $0 }
            .map { $0.toLKInfoType() }
    }
}

// MARK: - RTCDataChannelDelegate

extension DataChannelPairActor: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_: RTCDataChannel) {
        Task {
            if await isOpen {
                openCompleter.resume(returning: ())
            }
        }
    }

    nonisolated func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        log("dataChannel(didReceiveMessageWith:)")
        guard let dataPacket = try? Livekit_DataPacket(contiguousBytes: buffer.data) else {
            log("could not decode data message", .error)
            return
        }

        _onDataPacket?(dataPacket)
    }
}
