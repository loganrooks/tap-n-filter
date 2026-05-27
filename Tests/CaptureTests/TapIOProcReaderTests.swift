import AVFoundation
import CoreAudio
import Darwin
import XCTest
@testable import Capture

/// Unit tests for `TapIOProcReader`. Covers TDD anchors T2.1 through T2.8
/// from `docs/orchestration/phases/01-capture-spike-rework-1.md`.
///
/// The tests run against a `FakeCoreAudioInterface` so no real HAL state
/// is created. The IOProc-callback test (T2.6) invokes the file-scope C
/// IOProc with a synthesised `AudioBufferList`; this exercises the
/// `Unmanaged.fromOpaque` retrieval path without requiring an actual
/// aggregate device to fire.
@available(macOS 14.4, *)
final class TapIOProcReaderTests: XCTestCase {

    private let knownAudioProcessID: AudioObjectID = 42

    // MARK: T2.1 — init resolves format from tap's stream format

    func test_init_resolves_format_from_tap_stream_format() throws {
        let fake = FakeCoreAudioInterface()
        // 44.1 kHz × 2 ch — typical YouTube playback shape.
        fake.tapStreamFormatResult = { _ in
            var asbd = AudioStreamBasicDescription()
            asbd.mSampleRate = 44_100
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved
            asbd.mBytesPerPacket = 4
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = 4
            asbd.mChannelsPerFrame = 2
            asbd.mBitsPerChannel = 32
            return asbd
        }

        let reader = try TapIOProcReader(
            audioProcessID: knownAudioProcessID,
            coreAudio: fake
        )

        XCTAssertEqual(reader.format.sampleRate, 44_100)
        XCTAssertEqual(reader.format.channelCount, 2)
        XCTAssertEqual(fake.createTapCallProcessIDs, [knownAudioProcessID])
        XCTAssertEqual(fake.tapStreamFormatCallTapIDs.count, 1)
    }

    // MARK: T2.2 — ring buffer capacity equals rate × 2 seconds

    func test_init_allocates_ring_at_2_seconds_capacity() throws {
        let fake = FakeCoreAudioInterface()
        fake.tapStreamFormatResult = { _ in
            var asbd = AudioStreamBasicDescription()
            asbd.mSampleRate = 48_000
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved
            asbd.mBytesPerPacket = 4
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = 4
            asbd.mChannelsPerFrame = 2
            asbd.mBitsPerChannel = 32
            return asbd
        }

        let reader = try TapIOProcReader(
            audioProcessID: knownAudioProcessID,
            coreAudio: fake
        )
        XCTAssertEqual(reader.ring.capacity, 96_000)
        XCTAssertEqual(reader.ring.channelCount, 2)
    }

    // MARK: T2.3 — start succeeds; isRunning is true

    func test_start_succeeds_against_fake_aggregate_device() throws {
        let fake = FakeCoreAudioInterface()
        let reader = try TapIOProcReader(
            audioProcessID: knownAudioProcessID,
            coreAudio: fake
        )

        XCTAssertFalse(reader.isRunning)
        try reader.start()
        XCTAssertTrue(reader.isRunning)
        // The full creation order must have been: aggregate → tap list →
        // IOProc → startDevice.
        XCTAssertEqual(fake.createAggregateDeviceCallDescriptions.count, 1)
        XCTAssertEqual(fake.setAggregateTapListCalls.count, 1)
        XCTAssertEqual(fake.createIOProcIDCalls.count, 1)
        XCTAssertEqual(fake.startDeviceCalls.count, 1)
    }

    // MARK: T2.4 — start failure: no leaked tap; subsequent start succeeds

    func test_start_failure_at_createAggregate_does_not_leak_partial_state() throws {
        let fake = FakeCoreAudioInterface()
        var shouldFailNext = true
        fake.createAggregateDeviceResult = { _ in
            if shouldFailNext {
                throw CaptureError.aggregateDeviceCreationFailed(-1)
            }
            return 2_000
        }

        let reader = try TapIOProcReader(
            audioProcessID: knownAudioProcessID,
            coreAudio: fake
        )

        XCTAssertThrowsError(try reader.start()) { error in
            XCTAssertEqual(error as? CaptureError, .aggregateDeviceCreationFailed(-1))
        }
        XCTAssertFalse(reader.isRunning)
        // No IOProc was registered, nothing was started.
        XCTAssertTrue(fake.createIOProcIDCalls.isEmpty)
        XCTAssertTrue(fake.startDeviceCalls.isEmpty)
        // The tap created during init is still alive: the failed start
        // didn't destroy it (so we can retry).
        XCTAssertTrue(fake.destroyTapCallIDs.isEmpty)

        // Retry succeeds: tap is still there, fake stops failing.
        shouldFailNext = false
        try reader.start()
        XCTAssertTrue(reader.isRunning)
    }

    // MARK: T2.5 — stop is idempotent

    func test_stop_is_idempotent() throws {
        let fake = FakeCoreAudioInterface()
        let reader = try TapIOProcReader(
            audioProcessID: knownAudioProcessID,
            coreAudio: fake
        )
        try reader.start()

        reader.stop()
        reader.stop()  // must not crash; must not double-destroy
        XCTAssertFalse(reader.isRunning)
        // Each resource destroyed exactly once.
        XCTAssertEqual(fake.stopDeviceCalls.count, 1)
        XCTAssertEqual(fake.destroyIOProcIDCalls.count, 1)
        XCTAssertEqual(fake.destroyAggregateDeviceCallIDs.count, 1)
        XCTAssertEqual(fake.destroyTapCallIDs.count, 1)
    }

    // MARK: T2.6 — IOProc callback pushes samples into the ring buffer

    func test_ioproc_callback_pushes_samples_into_ring() throws {
        let fake = FakeCoreAudioInterface()
        let reader = try TapIOProcReader(
            audioProcessID: knownAudioProcessID,
            coreAudio: fake
        )

        // Build a fake non-interleaved Float32 buffer list with 2 channels
        // of 512 frames each. Sample value is 0.25; the test asserts the
        // ring received the data by inspecting fillCount and reading back.
        let frames = 512
        let bytes = frames * MemoryLayout<Float>.size
        let ch0 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let ch1 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            ch0.deallocate()
            ch1.deallocate()
        }
        ch0.initialize(repeating: 0.25)
        ch1.initialize(repeating: -0.25)

        // AudioBufferList layout: header with mNumberBuffers=2, then 2
        // AudioBuffer entries (non-interleaved = one buffer per channel).
        let listSize = MemoryLayout<UInt32>.size
            + 2 * MemoryLayout<AudioBuffer>.size
        let listRaw = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listRaw.deallocate() }
        let listPtr = listRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        // mNumberBuffers is the first 4 bytes; mBuffers is a single
        // entry inline. We need to write two AudioBuffers; access via
        // UnsafeMutableAudioBufferListPointer guarantees correct layout.
        listPtr.pointee.mNumberBuffers = 2
        let mutable = UnsafeMutableAudioBufferListPointer(listPtr)
        mutable[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(bytes),
            mData: UnsafeMutableRawPointer(ch0)
        )
        mutable[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(bytes),
            mData: UnsafeMutableRawPointer(ch1)
        )

        // Invoke the file-scope C IOProc directly with the reader as the
        // opaque clientData. This is exactly what the HAL would do.
        let clientData = Unmanaged.passUnretained(reader).toOpaque()
        var inputTime = AudioTimeStamp()
        var nowTime = AudioTimeStamp()
        var outputTime = AudioTimeStamp()
        _ = tapIOProcReaderIOProc(
            0,  // inDevice (ignored by callback)
            &nowTime,
            UnsafePointer(listPtr),
            &inputTime,
            UnsafeMutablePointer(listPtr),
            &outputTime,
            clientData
        )

        XCTAssertEqual(reader.ring.fillCount, frames)

        // Read the frames back and verify the sample values landed in
        // the right channel.
        let dch0 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let dch1 = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            dch0.deallocate()
            dch1.deallocate()
        }
        let read = reader.ring.read(into: [dch0, dch1], frames: frames)
        XCTAssertEqual(read, frames)
        for i in 0..<frames {
            XCTAssertEqual(dch0[i], 0.25)
            XCTAssertEqual(dch1[i], -0.25)
        }
    }

    // MARK: T2.7 — destroyTap and destroyAggregateDevice are called by stop

    func test_stop_calls_destroyTap_and_destroyAggregateDevice() throws {
        let fake = FakeCoreAudioInterface()
        let reader = try TapIOProcReader(
            audioProcessID: knownAudioProcessID,
            coreAudio: fake
        )
        try reader.start()
        let tapID = fake.createTapCallProcessIDs[0] + 1_000
        let aggregateID = fake.createAggregateDeviceCallDescriptions.count > 0 ? AudioDeviceID(2_000) : AudioDeviceID(0)
        XCTAssertEqual(aggregateID, 2_000) // sanity: fake's default

        reader.stop()

        XCTAssertEqual(fake.destroyTapCallIDs, [tapID])
        XCTAssertEqual(fake.destroyAggregateDeviceCallIDs, [aggregateID])
    }

    // MARK: T2.8 — aggregate creation dictionary has the required keys

    func test_aggregate_creation_dictionary_has_required_keys() throws {
        let fake = FakeCoreAudioInterface()
        let reader = try TapIOProcReader(
            audioProcessID: knownAudioProcessID,
            coreAudio: fake
        )
        try reader.start()

        XCTAssertEqual(fake.createAggregateDeviceCallDescriptions.count, 1)
        let dict = fake.createAggregateDeviceCallDescriptions[0] as NSDictionary

        // SubDeviceList must be present as an array (empty is allowed).
        let subDeviceList = dict.object(forKey: kAudioAggregateDeviceSubDeviceListKey as String)
        XCTAssertNotNil(subDeviceList, "SubDeviceList key missing")
        XCTAssertTrue(
            subDeviceList is NSArray,
            "SubDeviceList must be a CFArray (got \(type(of: subDeviceList)))"
        )
        XCTAssertEqual((subDeviceList as? NSArray)?.count, 0,
                       "SubDeviceList must be empty per EXP-026")

        // MasterSubDevice must be 0.
        let masterSubDevice = dict.object(forKey: kAudioAggregateDeviceMasterSubDeviceKey as String)
        XCTAssertNotNil(masterSubDevice, "MasterSubDevice key missing")
        XCTAssertEqual(
            (masterSubDevice as? NSNumber)?.intValue,
            0,
            "MasterSubDevice must be 0 per EXP-026"
        )

        // TapList must NOT be present at creation time.
        XCTAssertNil(
            dict.object(forKey: kAudioAggregateDeviceTapListKey as String),
            "TapList must NOT be in creation dict (set via setAggregateTapList)"
        )
        // TapAutoStart must NOT be present.
        XCTAssertNil(
            dict.object(forKey: kAudioAggregateDeviceTapAutoStartKey as String),
            "TapAutoStartKey must NOT be in creation dict"
        )

        // Other expected keys (Name, UID, IsPrivate, IsStacked).
        XCTAssertNotNil(dict.object(forKey: kAudioAggregateDeviceNameKey as String))
        XCTAssertNotNil(dict.object(forKey: kAudioAggregateDeviceUIDKey as String))
        XCTAssertEqual(
            (dict.object(forKey: kAudioAggregateDeviceIsPrivateKey as String) as? NSNumber)?.boolValue,
            true
        )
        XCTAssertEqual(
            (dict.object(forKey: kAudioAggregateDeviceIsStackedKey as String) as? NSNumber)?.boolValue,
            false
        )

        // The tap-list post-set call must have happened and must have
        // carried a 1-element array of CFStrings (the tap UID).
        XCTAssertEqual(fake.setAggregateTapListCalls.count, 1)
        let tapArray = fake.setAggregateTapListCalls[0].tapUIDs as NSArray
        XCTAssertEqual(tapArray.count, 1)
        XCTAssertTrue(
            tapArray[0] is String,
            "Tap list payload element must be a CFString (got \(type(of: tapArray[0])))"
        )
    }
}
