import XCTest
@testable import ErsatzCore

final class MetadataTests: XCTestCase {
    func testJPEGEXIFAndOrientation() async throws {
        let data = SampleFiles.jpeg(
            width: 4608,
            height: 3072,
            make: "Canon",
            model: "EOS R5",
            date: "2024:06:01 12:00:00",
            orientation: 6
        )
        let url = try write(data, name: "frame.jpg")
        let meta = await PortableMetadataExtractor().extract(from: url, kind: .photo)
        XCTAssertEqual(meta.formatName, "JPEG")
        XCTAssertEqual(meta.pixelWidth, 3072)
        XCTAssertEqual(meta.pixelHeight, 4608)
        XCTAssertEqual(meta.cameraModel, "Canon EOS R5")
        let parts = meta.dateTaken.flatMap(CalendarParts.yearMonth(of:))
        XCTAssertEqual(parts?.year, 2024)
        XCTAssertEqual(parts?.month, 6)
    }

    func testPNGDimensions() async throws {
        let url = try write(SampleFiles.png(width: 32, height: 16), name: "sheet.png")
        let meta = await PortableMetadataExtractor().extract(from: url, kind: .photo)
        XCTAssertEqual(meta.pixelWidth, 32)
        XCTAssertEqual(meta.pixelHeight, 16)
        XCTAssertEqual(meta.formatName, "PNG")
    }

    func testGIFAndBMP() async throws {
        let gif = try write(SampleFiles.gif(width: 12, height: 8), name: "anim.gif")
        let gifMeta = await PortableMetadataExtractor().extract(from: gif, kind: .photo)
        XCTAssertEqual(gifMeta.pixelWidth, 12)
        XCTAssertEqual(gifMeta.pixelHeight, 8)

        var bytes = [UInt8](repeating: 0, count: 26)
        bytes[0] = 0x42
        bytes[1] = 0x4D
        bytes[18] = 20
        bytes[22] = 10
        let bmpURL = try write(Data(bytes), name: "tiny.bmp")
        let bmpMeta = await PortableMetadataExtractor().extract(from: bmpURL, kind: .photo)
        XCTAssertEqual(bmpMeta.pixelWidth, 20)
        XCTAssertEqual(bmpMeta.pixelHeight, 10)
        XCTAssertEqual(bmpMeta.formatName, "BMP")
    }

    func testRAWUsesExtensionAndTIFFTags() async throws {
        let data = SampleFiles.tiff(
            littleEndian: false,
            width: 6000,
            height: 4000,
            make: "NIKON CORPORATION",
            model: "NIKON Z 8",
            date: "2023:11:02 09:30:00",
            orientation: 1
        )
        let url = try write(data, name: "plate.dng")
        let meta = await PortableMetadataExtractor().extract(from: url, kind: .raw)
        XCTAssertEqual(meta.formatName, "DNG")
        XCTAssertEqual(meta.pixelWidth, 6000)
        XCTAssertEqual(meta.pixelHeight, 4000)
        XCTAssertEqual(meta.cameraModel, "NIKON Z 8")
        let parts = meta.dateTaken.flatMap(CalendarParts.yearMonth(of:))
        XCTAssertEqual(parts?.year, 2023)
        XCTAssertEqual(parts?.month, 11)
    }

    func testWAVDurationAndCodec() async throws {
        let url = try write(SampleFiles.wav(sampleRate: 8000, channels: 1, bits: 16, frames: 8000), name: "tone.wav")
        let meta = await PortableMetadataExtractor().extract(from: url, kind: .audio)
        XCTAssertEqual(meta.audioCodec, "PCM")
        XCTAssertEqual(meta.formatName, "WAV")
        XCTAssertEqual(meta.duration ?? 0, 1.0, accuracy: 0.001)
    }

    func testAIFFDuration() async throws {
        let url = try write(SampleFiles.aiff(sampleRate: 44100, frames: 44100), name: "tone.aiff")
        let meta = await PortableMetadataExtractor().extract(from: url, kind: .audio)
        XCTAssertEqual(meta.audioCodec, "PCM")
        XCTAssertEqual(meta.duration ?? 0, 1.0, accuracy: 0.01)
    }

    func testFLACDuration() async throws {
        let url = try write(SampleFiles.flac(sampleRate: 48000, samples: 96000), name: "tone.flac")
        let meta = await PortableMetadataExtractor().extract(from: url, kind: .audio)
        XCTAssertEqual(meta.audioCodec, "FLAC")
        XCTAssertEqual(meta.duration ?? 0, 2.0, accuracy: 0.001)
    }

    func testMP3Duration() async throws {
        let url = try write(SampleFiles.mp3(durationSeconds: 1), name: "song.mp3")
        let meta = await PortableMetadataExtractor().extract(from: url, kind: .audio)
        XCTAssertEqual(meta.audioCodec, "MP3")
        XCTAssertEqual(meta.duration ?? 0, 1.0, accuracy: 0.02)
    }

    func testMP4CodecsDimensionsAndDuration() async throws {
        let url = try write(SampleFiles.mp4(width: 320, height: 240, duration: 2500, timescale: 1000), name: "clip.mp4")
        let meta = await PortableMetadataExtractor().extract(from: url, kind: .video)
        XCTAssertEqual(meta.videoCodec, "H.264")
        XCTAssertEqual(meta.audioCodec, "AAC")
        XCTAssertEqual(meta.pixelWidth, 320)
        XCTAssertEqual(meta.pixelHeight, 240)
        XCTAssertEqual(meta.duration ?? 0, 2.5, accuracy: 0.001)
        XCTAssertEqual(meta.formatName, "MP4")
    }

    func testProResName() {
        XCTAssertEqual(CodecName.video(fourCC: "apch"), "ProRes 422 HQ")
        XCTAssertEqual(CodecName.video(fourCC: "hvc1"), "HEVC")
        XCTAssertEqual(CodecName.audio(fourCC: "mp4a"), "AAC")
    }

    func testCorruptJPEGStillReturnsFormat() async throws {
        let url = try write(Data([0xFF, 0xD8, 0x00, 0x11]), name: "broken.jpg")
        let meta = await PortableMetadataExtractor().extract(from: url, kind: .photo)
        XCTAssertEqual(meta.formatName, "JPEG")
        XCTAssertNil(meta.pixelWidth)
    }

    private func write(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ersatz-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }
}
