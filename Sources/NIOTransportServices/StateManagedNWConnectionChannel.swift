//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOTLS
import Dispatch
import Network
import Security

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
protocol NWConnectionSubstate: ActiveChannelSubstate {
    static func closeInput(state: inout ChannelState<Self>) throws
    static func closeOutput(state: inout ChannelState<Self>) throws
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal protocol StateManagedNWConnectionChannel: StateManagedChannel where ActiveSubstate: NWConnectionSubstate {
    var parameters: NWParameters { get }
    
    var _connection: NWConnection? { get set }

    var _connectionQueue: DispatchQueue { get }

    var _connectPromise: EventLoopPromise<Void>? { get set }

    var _outstandingRead: Bool { get set }

    var _options: ConnectionChannelOptions { get set }

    var _pendingWrites: CircularBuffer<PendingWrite> { get set }

    var _backpressureManager: BackpressureManager { get set }

    var _reuseAddress: Bool { get set }

    var _reusePort: Bool { get set }

    var _enablePeerToPeer: Bool { get set }
    
    var _inboundStreamOpen: Bool { get }
}

@available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
extension StateManagedNWConnectionChannel {
    internal func beginActivating0(to target: NWEndpoint, promise: EventLoopPromise<Void>?) {
        assert(self._connection == nil)
        assert(self._connectPromise == nil)
        self._connectPromise = promise

        let parameters = self.parameters

        // Network.framework munges REUSEADDR and REUSEPORT together, so we turn this on if we need
        // either.
        parameters.allowLocalEndpointReuse = self._reuseAddress || self._reusePort

        parameters.includePeerToPeer = self._enablePeerToPeer

        let connection = NWConnection(to: target, using: parameters)
        connection.stateUpdateHandler = self.stateUpdateHandler(newState:)
        connection.betterPathUpdateHandler = self.betterPathHandler
        connection.pathUpdateHandler = self.pathChangedHandler(newPath:)

        // Ok, state is ready. Let's go!
        self._connection = connection
        connection.start(queue: self._connectionQueue)
    }
    
    public func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard self.isActive else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }

        // TODO: We would ideally support all of IOData here, gotta work out how to do that without HOL blocking
        // all writes terribly.
        // My best guess at this time is that Data(contentsOf:) may mmap the file in question, which would let us
        // at least only block the network stack itself rather than our thread. I'm not certain though, especially
        // on Linux. Should investigate.
        let data = self.unwrapData(data, as: ByteBuffer.self)
        self._pendingWrites.append((data, promise))


        /// This may cause our writability state to change.
        if self._backpressureManager.writabilityChanges(whenQueueingBytes: data.readableBytes) {
            self.pipeline.fireChannelWritabilityChanged()
        }
    }
    
    public func flush0() {
        guard self.isActive else {
            return
        }

        guard let conn = self._connection else {
            preconditionFailure("nwconnection cannot be nil while channel is active")
        }

        func completionCallback(promise: EventLoopPromise<Void>?, sentBytes: Int) -> ((NWError?) -> Void) {
            return { error in
                if let error = error {
                    promise?.fail(error)
                } else {
                    promise?.succeed(())
                }

                if self._backpressureManager.writabilityChanges(whenBytesSent: sentBytes) {
                    self.pipeline.fireChannelWritabilityChanged()
                }
            }
        }

        conn.batch {
            while self._pendingWrites.count > 0 {
                let write = self._pendingWrites.removeFirst()
                let buffer = write.data
                let content = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
                conn.send(content: content, completion: .contentProcessed(completionCallback(promise: write.promise, sentBytes: buffer.readableBytes)))
            }
        }
    }
    
    public func localAddress0() throws -> SocketAddress {
        guard let localEndpoint = self._connection?.currentPath?.localEndpoint else {
            throw NIOTSErrors.NoCurrentPath()
        }
        // TODO: Support wider range of address types.
        return try SocketAddress(fromNWEndpoint: localEndpoint)
    }

    public func remoteAddress0() throws -> SocketAddress {
        guard let remoteEndpoint = self._connection?.currentPath?.remoteEndpoint else {
            throw NIOTSErrors.NoCurrentPath()
        }
        // TODO: Support wider range of address types.
        return try SocketAddress(fromNWEndpoint: remoteEndpoint)
    }

    internal func alreadyConfigured0(promise: EventLoopPromise<Void>?) {
        guard let connection = _connection else {
            promise?.fail(NIOTSErrors.NotPreConfigured())
            return
        }

        guard case .setup = connection.state else {
            promise?.fail(NIOTSErrors.NotPreConfigured())
            return
        }

        connection.stateUpdateHandler = self.stateUpdateHandler(newState:)
        connection.betterPathUpdateHandler = self.betterPathHandler
        connection.pathUpdateHandler = self.pathChangedHandler(newPath:)
        connection.start(queue: self._connectionQueue)
    }

    /// Perform a read from the network.
    ///
    /// This method has a slightly strange semantic, because we do not allow multiple reads at once. As a result, this
    /// is a *request* to read, and if there is a read already being processed then this method will do nothing.
    public func read0() {
        guard self._inboundStreamOpen && !self._outstandingRead else {
            return
        }

        guard let conn = self._connection else {
            preconditionFailure("Connection should not be nil")
        }

        // TODO: Can we do something sensible with these numbers?
        self._outstandingRead = true
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192, completion: self.dataReceivedHandler(content:context:isComplete:error:))
    }

    public func doClose0(error: Error) {
        guard let conn = self._connection else {
            // We don't have a connection to close here, so we're actually done. Our old state
            // was idle.
            assert(self._pendingWrites.count == 0)
            return
        }

        // Step 1 is to tell the network stack we're done.
        // TODO: Does this drop the connection fully, or can we keep receiving data? Must investigate.
        conn.cancel()

        // Step 2 is to fail all outstanding writes.
        self.dropOutstandingWrites(error: error)

        // Step 3 is to cancel a pending connect promise, if any.
        if let pendingConnect = self._connectPromise {
            self._connectPromise = nil
            pendingConnect.fail(error)
        }
    }

    public func doHalfClose0(error: Error, promise: EventLoopPromise<Void>?) {
        guard let conn = self._connection else {
            // We don't have a connection to half close, so fail the promise.
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }


        do {
            try ActiveSubstate.closeOutput(state: &self.state)
        } catch ChannelError.outputClosed {
            // Here we *only* fail the promise, no need to blow up the connection.
            promise?.fail(ChannelError.outputClosed)
            return
        } catch {
            // For any other error, this is fatal.
            self.close0(error: error, mode: .all, promise: promise)
            return
        }

        func completionCallback(for promise: EventLoopPromise<Void>?) -> ((NWError?) -> Void) {
            return { error in
                if let error = error {
                    promise?.fail(error)
                } else {
                    promise?.succeed(())
                }
            }
        }

        // It should not be possible to have a pending connect promise while we're doing half-closure.
        assert(self._connectPromise == nil)

        // Step 1 is to tell the network stack we're done.
        conn.send(content: nil, contentContext: .finalMessage, completion: .contentProcessed(completionCallback(for: promise)))

        // Step 2 is to fail all outstanding writes.
        self.dropOutstandingWrites(error: error)
    }

    public func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case let x as NIOTSNetworkEvents.ConnectToNWEndpoint:
            self.connect0(to: x.endpoint, promise: promise)
        default:
            promise?.fail(ChannelError.operationUnsupported)
        }
    }

    public func channelRead0(_ data: NIOAny) {
        // drop the data, do nothing
        return
    }

    public func errorCaught0(error: Error) {
        // Currently we don't do anything with errors that pass through the pipeline
        return
    }

    /// A function that will trigger a socket read if necessary.
    internal func readIfNeeded0() {
        if self._options.autoRead {
            self.pipeline.read()
        }
    }
    
    /// Called by the underlying `NWConnection` when its internal state has changed.
    private func stateUpdateHandler(newState: NWConnection.State) {
        switch newState {
        case .setup:
            preconditionFailure("Should not be told about this state.")
        case .waiting(let err):
            if case .activating = self.state, self._options.waitForActivity {
                // This means the connection cannot currently be completed. We should notify the pipeline
                // here, or support this with a channel option or something, but for now for the sake of
                // demos we will just allow ourselves into this stage.
                break
            }

            // In this state we've transitioned into waiting, presumably from active or closing. In this
            // version of NIO this is an error, but we should aim to support this at some stage.
            self.close0(error: err, mode: .all, promise: nil)
        case .preparing:
            // This just means connections are being actively established. We have no specific action
            // here.
            break
        case .ready:
            // Transitioning to ready means the connection was succeeded. Hooray!
            self.connectionComplete0()
        case .cancelled:
            // This is the network telling us we're closed. We don't need to actually do anything here
            // other than check our state is ok.
            assert(self.closed)
            self._connection = nil
        case .failed(let err):
            // The connection has failed for some reason.
            self.close0(error: err, mode: .all, promise: nil)
        default:
            // This clause is here to help the compiler out: it's otherwise not able to
            // actually validate that the switch is exhaustive. Trust me, it is.
            fatalError("Unreachable")
        }
    }

    /// Called by the underlying `NWConnection` when a network receive has completed.
    ///
    /// The state matrix here is large. If `content` is non-nil, some data was received: we need to send it down the pipeline
    /// and call channelReadComplete. This may be nil, in which case we expect either `isComplete` to be `true` or `error`
    /// to be non-nil. `isComplete` indicates half-closure on the read side of a connection. `error` is set if the receive
    /// did not complete due to an error, though there may still be some data.
    private func dataReceivedHandler(content: Data?, context: NWConnection.ContentContext?, isComplete: Bool, error: NWError?) {
        precondition(self._outstandingRead)
        self._outstandingRead = false

        guard self.isActive else {
            // If we're already not active, we aren't going to process any of this: it's likely the result of an extra
            // read somewhere along the line.
            return
        }

        // First things first, if there's data we need to deliver it.
        if let content = content {
            // It would be nice if we didn't have to do this copy, but I'm not sure how to avoid it with the current Data
            // APIs.
            var buffer = self.allocator.buffer(capacity: content.count)
            buffer.writeBytes(content)
            self.pipeline.fireChannelRead(NIOAny(buffer))
            self.pipeline.fireChannelReadComplete()
        }

        // Next, we want to check if there's an error. If there is, we're going to deliver it, and then close the connection with
        // it. Otherwise, we're going to check if we read EOF, and if we did we'll close with that instead.
        if let error = error {
            self.pipeline.fireErrorCaught(error)
            self.close0(error: error, mode: .all, promise: nil)
        } else if isComplete {
            self.didReadEOF()
        }

        // Last, issue a new read automatically if we need to.
        self.readIfNeeded0()
    }

    /// Called by the underlying `NWConnection` when a better path for this connection is available.
    ///
    /// Notifies the channel pipeline of the new option.
    private func betterPathHandler(available: Bool) {
        if available {
            self.pipeline.fireUserInboundEventTriggered(NIOTSNetworkEvents.BetterPathAvailable())
        } else {
            self.pipeline.fireUserInboundEventTriggered(NIOTSNetworkEvents.BetterPathUnavailable())
        }
    }

    /// Called by the underlying `NWConnection` when this connection changes its network path.
    ///
    /// Notifies the channel pipeline of the new path.
    private func pathChangedHandler(newPath path: NWPath) {
        self.pipeline.fireUserInboundEventTriggered(NIOTSNetworkEvents.PathChanged(newPath: path))
    }

    /// Handle a read EOF.
    ///
    /// If the user has indicated they support half-closure, we will emit the standard half-closure
    /// event. If they have not, we upgrade this to regular closure.
    private func didReadEOF() {
        if self._options.supportRemoteHalfClosure {
            // This is a half-closure, but the connection is still valid.
            do {
                try ActiveSubstate.closeInput(state: &self.state)
            } catch {
                return self.close0(error: error, mode: .all, promise: nil)
            }

            self.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        } else {
            self.close0(error: ChannelError.eof, mode: .all, promise: nil)
        }
    }

    /// Make the channel active.
    private func connectionComplete0() {
        let promise = self._connectPromise
        self._connectPromise = nil
        self.becomeActive0(promise: promise)

        if let metadata = self._connection?.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            // This is a TLS connection, we may need to fire some other events.
            let negotiatedProtocol = sec_protocol_metadata_get_negotiated_protocol(metadata.securityProtocolMetadata).map {
                String(cString: $0)
            }
            self.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: negotiatedProtocol))
        }
    }

    /// Drop all outstanding writes. Must only be called in the inactive
    /// state.
    private func dropOutstandingWrites(error: Error) {
        while self._pendingWrites.count > 0 {
            self._pendingWrites.removeFirst().promise?.fail(error)
        }
    }
}
#endif
