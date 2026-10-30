import ErsatzCore
import XCTest

final class ExternalPlaybackTests: XCTestCase {
    func testLocatorPrefersCustomThenHomebrewThenLocalThenPath() {
        XCTAssertTrue(ExternalPlayback.needsExternalPlayer(path: "/films/clip.MKV"))
        XCTAssertTrue(ExternalPlayback.needsExternalPlayer(path: "/films/clip.webm"))
        XCTAssertTrue(ExternalPlayback.needsExternalPlayer(path: "/films/clip.avi"))
        XCTAssertTrue(ExternalPlayback.needsExternalPlayer(path: "/films/clip.flv"))
        XCTAssertTrue(ExternalPlayback.needsExternalPlayer(path: "/films/clip.wmv"))
        XCTAssertFalse(ExternalPlayback.needsExternalPlayer(path: "/films/clip.mp4"))
        XCTAssertEqual(MediaTypeDetector.kind(for: "/films/clip.mkv"), .video)
        XCTAssertEqual(FormatNames.preferred(forExtension: "flv"), "FLV")
        XCTAssertEqual(FormatNames.preferred(forExtension: "wmv"), "WMV")

        var seen: [String] = []
        let missing = FFmpegLocator.locate(customPath: nil, pathEnvironment: "/opt/other/bin", isExecutable: { path in
            seen.append(path)
            return false
        })
        XCTAssertNil(missing)
        XCTAssertEqual(seen, [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/other/bin/ffmpeg"
        ])
        var paired: [String] = []
        let half = FFmpegLocator.locate(customPath: "/opt/homebrew/bin", pathEnvironment: nil, isExecutable: { path in
            paired.append(path)
            return path.hasSuffix("/ffmpeg")
        })
        XCTAssertNil(half)
        XCTAssertEqual(Array(paired.prefix(2)), ["/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffprobe"])

        let custom = FFmpegLocator.locate(
            customPath: "\"/Custom/bin/ffmpeg\"",
            pathEnvironment: "/opt/homebrew/bin",
            isExecutable: { $0.hasPrefix("/Custom/bin/") }
        )
        XCTAssertEqual(custom?.ffmpegPath, "/Custom/bin/ffmpeg")
        XCTAssertEqual(custom?.ffprobePath, "/Custom/bin/ffprobe")

        let directory = FFmpegLocator.locate(
            customPath: "/Custom/bin",
            pathEnvironment: nil,
            isExecutable: { $0.hasPrefix("/Custom/bin/") }
        )
        XCTAssertEqual(directory?.ffprobePath, "/Custom/bin/ffprobe")

        let fellThrough = FFmpegLocator.locate(
            customPath: "/missing/ffmpeg",
            pathEnvironment: nil,
            isExecutable: { $0.hasPrefix("/usr/local/bin/") }
        )
        XCTAssertEqual(fellThrough?.ffmpegPath, "/usr/local/bin/ffmpeg")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tilde = FFmpegLocator.locate(
            customPath: "~/bin",
            pathEnvironment: nil,
            isExecutable: { $0 == "\(home)/bin/ffmpeg" || $0 == "\(home)/bin/ffprobe" }
        )
        XCTAssertEqual(tilde?.ffmpegPath, "\(home)/bin/ffmpeg")

        let ffmpegOnly = FFmpegLocator.locate(
            customPath: "/opt/homebrew/bin",
            pathEnvironment: "/opt/other/bin",
            isExecutable: { $0.hasSuffix("/ffmpeg") }
        )
        XCTAssertNil(ffmpegOnly)
    }

    func testProbeChoosesRemuxOrTranscode() {
        XCTAssertEqual(report(video: "h264", audio: "aac")?.plan, .remux(hevcTag: false, includeAudio: true))
        XCTAssertEqual(report(video: "hevc", audio: "aac")?.plan, .remux(hevcTag: true, includeAudio: true))
        XCTAssertEqual(report(video: "h265", audio: nil)?.plan, .remux(hevcTag: true, includeAudio: false))
        for audio in ["alac", "mp3", "ac3", "eac3"] {
            XCTAssertEqual(report(video: "h264", audio: audio)?.plan, .remux(hevcTag: false, includeAudio: true), audio)
        }
        XCTAssertEqual(
            report(video: "vp9", audio: "opus")?.plan,
            .transcode(encoder: .h264, includeAudio: true)
        )
        XCTAssertEqual(
            report(video: "hevc", audio: "flac")?.plan,
            .transcode(encoder: .hevc, includeAudio: true)
        )
        XCTAssertEqual(
            report(video: "h264", audio: "vorbis")?.plan,
            .transcode(encoder: .h264, includeAudio: true)
        )
        XCTAssertEqual(report(video: nil, audio: "aac")?.plan, .unsupported("No video stream"))
        XCTAssertNil(FFProbeJSON.parse(Data("not-json".utf8)))
        XCTAssertEqual(report(video: "h264", audio: "aac")?.videoCodec, "H.264")
        XCTAssertEqual(report(video: "vp9", audio: "opus")?.audioCodec, "Opus")
        XCTAssertEqual(FFmpegCodecNames.video("wmv3"), "WMV")
        XCTAssertEqual(FFmpegCodecNames.audio("pcm_s16le"), "PCM")
    }

    func testProbeReadsDurationAndSkipsAttachedPictures() throws {
        let json = """
        {"streams":[
          {"codec_type":"video","codec_name":"mjpeg","width":120,"height":80,"disposition":{"attached_pic":1}},
          {"codec_type":"video","codec_name":"h264","width":1280,"height":720},
          {"codec_type":"audio","codec_name":"aac"}
        ],"format":{"tags":{"DURATION":"00:00:03.500000000"}}}
        """
        let parsed = try XCTUnwrap(FFProbeJSON.parse(Data(json.utf8)))
        XCTAssertEqual(parsed.width, 1280)
        XCTAssertEqual(parsed.height, 720)
        XCTAssertEqual(parsed.duration ?? 0, 3.5, accuracy: 0.001)
        XCTAssertEqual(parsed.videoCodecRaw, "h264")
        XCTAssertEqual(parsed.plan, .remux(hevcTag: false, includeAudio: true))
        let metadata = parsed.metadata(formatName: "MKV")
        XCTAssertEqual(metadata.videoCodec, "H.264")
        XCTAssertEqual(metadata.audioCodec, "AAC")
        XCTAssertEqual(metadata.formatName, "MKV")
        XCTAssertEqual(metadata.pixelWidth, 1280)
        XCTAssertNil(metadata.dateTaken)
    }

    func testCommandArguments() {
        let input = "/films/clip.mkv"
        let output = "/tmp/ersatz/out.mp4"
        let remux = FFmpegArguments.make(
            plan: .remux(hevcTag: true, includeAudio: false),
            input: input,
            output: output
        )
        XCTAssertEqual(remux, [
            "-y", "-i", input, "-map", "0:V:0", "-c", "copy", "-tag:v", "hvc1",
            "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output
        ])
        let transcode = FFmpegArguments.make(
            plan: .transcode(encoder: .h264, includeAudio: true),
            input: input,
            output: output
        )
        XCTAssertEqual(transcode, [
            "-y", "-i", input, "-map", "0:V:0", "-map", "0:a:0",
            "-c:v", "h264_videotoolbox", "-c:a", "aac",
            "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output
        ])
        let hevc = FFmpegArguments.make(
            plan: .transcode(encoder: .hevc, includeAudio: true),
            input: input,
            output: output
        )
        XCTAssertEqual(hevc?[hevc?.firstIndex(of: "-c:v") ?? 0], "-c:v")
        XCTAssertTrue(hevc?.contains("hevc_videotoolbox") == true)
        XCTAssertTrue(hevc?.contains("hvc1") == true)
        XCTAssertTrue(hevc?.contains("aac") == true)
        XCTAssertNil(FFmpegArguments.make(plan: .unsupported("No video stream"), input: input, output: output))
        XCTAssertNil(FFmpegArguments.make(plan: .remux(hevcTag: false, includeAudio: false), input: "/tmp/a.mp4", output: "/tmp/../tmp/a.mp4"))
        XCTAssertTrue(PlaybackPaths.sameFile("/tmp/a.mp4", "/tmp/../tmp/a.mp4"))

        let probe = FFmpegArguments.probe(input: input)
        XCTAssertEqual(probe.first, "-v")
        XCTAssertTrue(probe.contains("json"))
        XCTAssertEqual(probe.last, input)
        XCTAssertEqual(probe.filter { $0 == input }.count, 1)

        let thumb = FFmpegArguments.thumbnail(input: input, output: "/tmp/frame.jpg", seekSeconds: 1, maxSide: 512)
        XCTAssertEqual(thumb, [
            "-y", "-ss", "1.000", "-i", input, "-frames:v", "1", "-an",
            "-vf", "scale=512:512:force_original_aspect_ratio=decrease", "/tmp/frame.jpg"
        ])
        XCTAssertNotEqual(thumb.last, input)
    }

    func testProgressLines() {
        var parser = FFmpegProgressParser(duration: 10)
        XCTAssertNil(parser.ingest("out_time_us=2500"))
        XCTAssertEqual(parser.ingest("000\nout_time=00:00:05.000000\n") ?? -1, 0.5, accuracy: 0.001)
        var clock = FFmpegProgressParser(duration: 8)
        XCTAssertEqual(clock.ingest("out_time_ms=4000000\n") ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(clock.ingest("progress=end\n") ?? -1, 1, accuracy: 0.001)
        var unknown = FFmpegProgressParser(duration: 0)
        XCTAssertNil(unknown.ingest("out_time_us=1000\n"))
        XCTAssertEqual(unknown.ingest("progress=end\n") ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(FFmpegProgressParser.parseClock("01:02:03.5") ?? 0, 3723.5, accuracy: 0.001)
        var overflow = FFmpegProgressParser(duration: 4)
        XCTAssertEqual(overflow.ingest("out_time=00:00:09.000000\n") ?? -1, 1, accuracy: 0.001)
    }

    func testCacheKeyAndLRU() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = PlaybackCacheKey.filename(path: "/films/clip.mkv", fileSize: 42, modifiedAt: date)
        XCTAssertEqual(name.count, 68)
        XCTAssertTrue(name.hasSuffix(".mp4"))
        XCTAssertEqual(name, PlaybackCacheKey.filename(path: "/films/clip.mkv", fileSize: 42, modifiedAt: date))
        XCTAssertNotEqual(name, PlaybackCacheKey.filename(path: "/films/clip.mkv", fileSize: 43, modifiedAt: date))
        XCTAssertNotEqual(name, PlaybackCacheKey.filename(path: "/films/other.mkv", fileSize: 42, modifiedAt: date))
        XCTAssertEqual(PlaybackCachePolicy.defaultMaxBytes, 5 * 1024 * 1024 * 1024)
        XCTAssertEqual(PlaybackCachePolicy.bytes(gigabytes: 5), PlaybackCachePolicy.defaultMaxBytes)
        XCTAssertEqual(PlaybackCachePolicy.bytes(gigabytes: 0.1), 1024 * 1024 * 1024)

        let older = PlaybackCacheEntry(path: "/cache/old.mp4", bytes: 800, lastUsed: Date(timeIntervalSince1970: 10))
        let newer = PlaybackCacheEntry(path: "/cache/new.mp4", bytes: 800, lastUsed: Date(timeIntervalSince1970: 20))
        let kept = CacheEviction.victims(entries: [newer, older], maxBytes: 1000)
        XCTAssertEqual(kept.map(\.path), ["/cache/old.mp4"])
        let protected = CacheEviction.victims(entries: [newer, older], maxBytes: 100, protecting: "/cache/new.mp4")
        XCTAssertEqual(protected.map(\.path), ["/cache/old.mp4"])
        XCTAssertTrue(CacheEviction.victims(entries: [newer], maxBytes: 800).isEmpty)
        XCTAssertTrue(FFmpegInstallGuide.summary.contains(FFmpegInstallGuide.brewCommand))
        XCTAssertTrue(FFmpegInstallGuide.summary.contains("/opt/homebrew/bin"))
        XCTAssertTrue(FFmpegInstallGuide.summary.contains("/usr/local/bin"))
        XCTAssertTrue(FFmpegInstallGuide.summary.contains("PATH"))
    }

    func testPlaybackCacheFilesAndInstallGuide() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let cache = try PlaybackCache(directory: scratch.root.appendingPathComponent("Playback"))
        let modified = Date(timeIntervalSince1970: 50)
        let url = cache.fileURL(path: "/films/clip.mkv", fileSize: 9, modifiedAt: modified)
        XCTAssertNil(cache.existing(path: "/films/clip.mkv", fileSize: 9, modifiedAt: modified))
        try Data("mp4".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 60)],
            ofItemAtPath: url.path
        )
        let hit = cache.existing(path: "/films/clip.mkv", fileSize: 9, modifiedAt: modified)
        XCTAssertEqual(hit?.path, url.path)
        XCTAssertNil(cache.existing(path: "/films/clip.mkv", fileSize: 10, modifiedAt: modified))
        let touched = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertGreaterThan(touched ?? .distantPast, Date(timeIntervalSince1970: 10_000))

        let emptyURL = cache.fileURL(path: "/films/empty.mkv", fileSize: 1, modifiedAt: modified)
        try Data().write(to: emptyURL)
        XCTAssertNil(cache.existing(path: "/films/empty.mkv", fileSize: 1, modifiedAt: modified))

        let old = cache.directory.appendingPathComponent("old.mp4")
        let fresh = cache.directory.appendingPathComponent("fresh.mp4")
        try Data(count: 1000).write(to: old)
        try Data(count: 1000).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: fresh.path
        )
        try cache.enforceLimit(maxBytes: 1500, protecting: fresh.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let playback = try AppPaths.playbackCacheURL()
        XCTAssertEqual(playback.lastPathComponent, "Playback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: playback.path))
    }

    private func report(video: String?, audio: String?) -> ProbeReport? {
        var streams: [String] = []
        if let video {
            streams.append("""
            {"codec_type":"video","codec_name":"\(video)","width":1920,"height":1080,"duration":"10"}
            """)
        }
        if let audio {
            streams.append("""
            {"codec_type":"audio","codec_name":"\(audio)"}
            """)
        }
        let json = """
        {"streams":[\(streams.joined(separator: ","))],"format":{"duration":"10"}}
        """
        return FFProbeJSON.parse(Data(json.utf8))
    }
}
