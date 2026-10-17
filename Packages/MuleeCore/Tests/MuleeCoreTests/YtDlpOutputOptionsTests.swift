import Foundation
import Testing
@testable import MuleeCore

@Suite struct YtDlpOutputOptionsTests {
    @Test func compatibleAutoKeepsOriginalSelectorAndFilename() {
        let options = YtDlpOutputOptions()
        #expect(options.arguments(quality: .compatible, site: .other) == [
            "--format", "bv[vcodec~='^(avc1|h264)']+ba[acodec~='^(mp4a|aac)']/bv[vcodec~='^(hev1|hvc1|hevc)']+ba[acodec~='^(mp4a|aac)']/b[vcodec~='^(avc1|h264|hev1|hvc1|hevc)'][acodec~='^(mp4a|aac)']/b[ext=mp4][vcodec~=?'^(avc1|h264|hev1|hvc1|hevc)'][acodec~=?'^(mp4a|aac)']",
            "--merge-output-format", "mp4", "--remux-video", "mp4",
            "--embed-metadata", "--embed-chapters", "--no-embed-info-json", "--embed-thumbnail"
        ])
        #expect(options.filenamePreset.template == "%(title).160B.%(ext)s")
        #expect(!options.autoCaptions && !options.prefer60fps && !options.sponsorBlockMark)
    }

    @Test(arguments: YtDlpOutputOptions.SubtitleMode.allCases, [false, true])
    func subtitlesRespectModeAndAutomaticCaptions(mode: YtDlpOutputOptions.SubtitleMode, automatic: Bool) {
        var options = YtDlpOutputOptions()
        options.subtitleMode = mode
        options.autoCaptions = automatic
        options.subtitleLanguages = ["en"]
        let arguments = options.arguments(quality: .best, site: .youtube, task: .init(subtitleLanguages: ["zh-Hans", "en"]))
        #expect(arguments.contains("--write-subs") == (mode != .off))
        #expect(arguments.contains("--embed-subs") == (mode == .embed))
        #expect(arguments.contains("--convert-subs") == (mode == .file))
        #expect(arguments.contains("--write-auto-subs") == (automatic && mode != .off))
        #expect(arguments.contains("^zh-Hans$,^en$") == (mode != .off))
        let deselected = options.arguments(quality: .best, site: .other, task: .init(subtitleLanguages: []))
        #expect(!deselected.contains("--write-subs"))
        let global = options.arguments(quality: .best, site: .other)
        #expect(global.contains("^en$") == (mode != .off))
    }

    @Test(arguments: YtDlpOutputOptions.CodecPreference.allCases, [false, true])
    func codecAndFrameRateCombineWithBothQualities(codec: YtDlpOutputOptions.CodecPreference, sixty: Bool) throws {
        for quality in [YtDlpQuality.compatible, .best] {
            var options = YtDlpOutputOptions()
            options.codecPreference = codec
            options.prefer60fps = sixty
            let arguments = options.arguments(quality: quality, site: .other)
            #expect(arguments.contains("-S") == (codec != .auto || sixty))
            if let sortIndex = arguments.firstIndex(of: "-S") {
                let expectedCodec: String? = switch codec {
                case .auto: nil
                case .h264: "vcodec:h264"
                case .hevc: "vcodec:h265"
                case .av1: "vcodec:av1"
                case .vp9: "vcodec:vp9"
                }
                #expect(arguments[sortIndex + 1] == [expectedCodec, sixty ? "fps:60" : nil].compactMap { $0 }.joined(separator: ","))
            }
            #expect(arguments[3] == (quality == .compatible ? "mp4" : "mkv"))
            if codec != .auto {
                #expect(arguments[1] == (quality == .compatible
                    ? "bv*+ba[acodec~='^(mp4a|aac)']/bv*+ba/b" : "bv*+ba/b"))
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func metadataAndSponsorFlagsAreIndependent(metadata: Bool, sponsor: Bool) {
        for site in [VideoSite.youtube, .bilibili, .other] {
            var options = YtDlpOutputOptions()
            options.embedMetadata = metadata
            options.sponsorBlockMark = sponsor
            let arguments = options.arguments(quality: .compatible, site: site)
            #expect(arguments.contains("--embed-metadata") == metadata)
            #expect(arguments.contains("--embed-thumbnail") == metadata)
            #expect(arguments.contains("--sponsorblock-mark") == (sponsor && site == .youtube))
            #expect(arguments.contains("--embed-chapters") == (metadata || (sponsor && site == .youtube)))
            #expect(!arguments.contains("--sponsorblock-remove"))
            let fallback = options.arguments(quality: .compatible, site: site, includeThumbnail: false)
            #expect(!fallback.contains("--embed-thumbnail"))
            #expect(fallback.contains("--embed-metadata") == metadata)
        }
    }

    @Test(arguments: YtDlpOutputOptions.AudioFormat.allCases)
    func audioOnlySkipsVideoAndAllSubtitles(format: YtDlpOutputOptions.AudioFormat) {
        var options = YtDlpOutputOptions()
        options.audioFormat = format
        options.subtitleMode = .embed
        options.autoCaptions = true
        for site in [VideoSite.bilibili, .youtube, .other] {
            let arguments = options.arguments(
                quality: .best, site: site, task: .init(subtitleLanguages: ["en"], audioOnly: true),
                formatID: "720", bilibiliSubtitles: .init(danmaku: true, closedCaptions: true)
            )
            #expect(Array(arguments.prefix(5)) == ["-f", "bestaudio", "-x", "--audio-format", format.rawValue])
            for flag in ["--embed-subs", "--write-subs", "--write-auto-subs", "--remux-video", "--format"] {
                #expect(!arguments.contains(flag))
            }
        }
    }

    @Test func bilibiliAndExplicitFormatKeepExistingArguments() {
        var options = YtDlpOutputOptions()
        options.subtitleMode = .file
        options.autoCaptions = true
        let arguments = options.arguments(
            quality: .best, site: .bilibili, formatID: "720", formatVideoOnly: true,
            bilibiliSubtitles: .init(danmaku: true, closedCaptions: true)
        )
        #expect(arguments.contains("720+ba/720"))
        #expect(arguments.contains("all"))
        #expect(!arguments.contains("--convert-subs"))
        #expect(!arguments.contains("--write-auto-subs"))
    }

    @Test func filenamePresetsAreFixedAndByteBounded() {
        let expected = [
            "%(title).160B.%(ext)s",
            "%(uploader,channel|Unknown).40B - %(title).117B.%(ext)s",
            "%(upload_date>%Y-%m-%d|Unknown)s - %(title).147B.%(ext)s"
        ]
        #expect(YtDlpOutputOptions.FilenamePreset.allCases.map(\.template) == expected)
        #expect(40 + 3 + 117 == 160)
        #expect(10 + 3 + 147 == 160)
    }

    @Test(arguments: [("0", "1", "*0-1"), ("01:02", "02:03", "*62-123"), ("1:02:03", "1:02:04.5", "*3723-3724.5"), (" 0.5 ", "1.25", "*0.5-1.25"), ("0.0000001", "1", "*0.0000001-1")])
    func parsesTimeRange(input: (String, String, String)) throws {
        let section = try YtDlpTimeSection(start: input.0, end: input.1)
        #expect(section.argument == input.2)
        let arguments = YtDlpOutputOptions().arguments(quality: .best, site: .youtube, task: .init(section: section))
        #expect(Array(arguments.suffix(2)) == ["--download-sections", input.2])
    }

    @Test(arguments: ["", "-1", "nan", "inf", "1:60", "1::2", "1:02:60", "1:2:3:4", "1.5:00", "1e9", "1;echo", "."])
    func rejectsMalformedTime(value: String) {
        #expect(YtDlpTimeSection.seconds(value) == nil)
        #expect(throws: YtDlpTimeSection.ValidationError.self) { try YtDlpTimeSection(start: value, end: "100") }
    }

    @Test func rejectsReversedEmptyAndUntrustedPersistedSections() throws {
        for times in [("10", "10"), ("20", "10"), ("0", "")] {
            #expect(throws: YtDlpTimeSection.ValidationError.self) { try YtDlpTimeSection(start: times.0, end: times.1) }
        }
        let section = try JSONDecoder().decode(YtDlpTimeSection.self, from: Data(#"{"start":20,"end":10}"#.utf8))
        #expect(throws: YtDlpTimeSection.ValidationError.self) { try YtDlpTaskOptions(section: section).validate() }
        #expect(throws: EngineError.self) { try YtDlpTaskOptions(subtitleLanguages: ["all,-en"]).validate() }
    }

    @Test func subtitleDefaultsMapSystemLanguagesAndMatchAvailableAliases() {
        let preferences = YtDlpOutputOptions.preferredSubtitleLanguages(["zh-Hans-CN", "en-US", "en-GB", "zh-TW", "ja-JP"])
        #expect(preferences == ["zh-Hans", "en", "zh-Hant", "ja"])
        #expect(YtDlpSubtitleLanguage.preferredIDs(in: ["zh-CN", "en", "fr", "zh-TW"], preferences: preferences) == ["zh-CN", "en", "zh-TW"])
    }

    @Test func optionsDecodeOldDataAndRoundTrip() throws {
        let old = try JSONDecoder().decode(YtDlpTaskOptions.self, from: Data("{}".utf8))
        #expect(old == YtDlpTaskOptions())
        let original = YtDlpTaskOptions(subtitleLanguages: [], audioOnly: true, section: try .init(start: "0", end: "10"))
        #expect(try JSONDecoder().decode(YtDlpTaskOptions.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test(arguments: YtDlpOutputOptions.AudioFormat.allCases)
    func audioFinalPathFindsConvertedFileAndRenamesSidecars(format: YtDlpOutputOptions.AudioFormat) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let reported = root.appendingPathComponent(id + "-Example.webm")
        let audio = reported.deletingPathExtension().appendingPathExtension(format.rawValue)
        try Data("audio".utf8).write(to: audio)
        try Data("image".utf8).write(to: reported.deletingPathExtension().appendingPathExtension("jpg"))
        let resolved = try YtDlpFinalName.resolve(reported, audioFormat: format)
        let renamed = try YtDlpFinalName.finalize(resolved, jobID: id)
        #expect(renamed.file.lastPathComponent == "Example." + format.rawValue)
        #expect(Set(renamed.names) == ["Example." + format.rawValue, "Example.jpg"])
        #expect(throws: EngineError.self) { try YtDlpFinalName.resolve(reported, audioFormat: nil) }
    }

    @Test func thumbnailFallbackRecognizesOnlyCoverErrors() {
        #expect(YtDlpFinalName.isThumbnailFailure("ERROR: Postprocessing: Supported filetypes for thumbnail embedding are: mp3, mkv"))
        #expect(YtDlpFinalName.isThumbnailFailure("ERROR: Postprocessing: Unable to embed using ffprobe & ffmpeg; failure"))
        #expect(YtDlpFinalName.isThumbnailFailure("[ThumbnailsConvertor] Converting thumbnail\nERROR: Postprocessing: Conversion failed"))
        #expect(!YtDlpFinalName.isThumbnailFailure("[EmbedThumbnail] Adding thumbnail\n[Metadata] Adding metadata\nERROR: Postprocessing: ffmpeg failed"))
        #expect(!YtDlpFinalName.isThumbnailFailure("ERROR: Postprocessing: Unable to embed subtitles"))
        #expect(!YtDlpFinalName.isThumbnailFailure("ERROR: unable to download video data: HTTP Error 403"))
        #expect(!YtDlpFinalName.isThumbnailFailure("ERROR: Postprocessing: Unable to embed thumbnail\nERROR: unable to download video"))
    }

    @Test(arguments: [false, true])
    func engineRecoversCoverFailureAndSkipsAudioDanmaku(audioOnly: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        let script = #"""
        #!/bin/sh
        cover=0
        format=mp4
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --paths) directory="$2"; shift 2 ;;
                --output) template="$2"; shift 2 ;;
                --audio-format) format="$2"; shift 2 ;;
                --cookies) [ -s "$2" ] || exit 8; shift 2 ;;
                --embed-thumbnail) cover=1; shift ;;
                --embed-subs|--write-subs) exit 7 ;;
                *) shift ;;
            esac
        done
        prefix="${template%%\%*}"
        file="$directory/${prefix}Example.$format"
        printf '%s' 'media' > "$file"
        printf '%s' '<i><d p="0,1,25,0">example</d></i>' > "${file%.*}.danmaku.xml"
        printf '%s\n' "$cover" >> "$directory/attempts"
        if [ "$cover" = 1 ]; then
            echo '[EmbedThumbnail] ffmpeg: Adding thumbnail'
            echo 'ERROR: Postprocessing: Supported filetypes for thumbnail embedding are: mp3, mkv'
            exit 1
        fi
        printf 'MULEE:{"event":"file","path":"%s"}\n' "$file"
        """#
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let engine = YtDlpEngine(
            stateDirectory: root.appendingPathComponent("state"), binaryURL: binary, installer: nil,
            subtitles: .init(danmaku: audioOnly), updatesEnabled: false
        )
        await engine.configureCookies { _ in
            [VideoCookie(domain: "bilibili.com", path: "/", name: "session", value: "example",
                         secure: true, httpOnly: true, hostOnly: true)]
        }
        do {
            try await engine.start(options: .init(downloadDirectory: root))
            let url = try #require(URL(string: "https://example.com/video/Example0001"))
            let id = try await engine.add(
                link: .video(url: url, site: .bilibili, original: url.absoluteString), directory: root, entry: nil,
                outputOptions: .init(audioOnly: audioOnly)
            )
            let done = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .completed }
            let file = try #require(done.savePath)
            #expect(file.lastPathComponent == (audioOnly ? "Example.m4a" : "Example.mp4"))
            #expect(done.errorMessage == nil)
            #expect(try String(contentsOf: root.appendingPathComponent("attempts"), encoding: .utf8) == "1\n0\n")
            if audioOnly {
                #expect(!FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("danmaku.ass").path))
                #expect(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("danmaku.xml").path))
            }
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }


    @Test(arguments: [false, true], [false, true])
    func sectionsNeverEmbedFullVideoChaptersOrQuerySponsors(metadata: Bool, sponsors: Bool) throws {
        var options = YtDlpOutputOptions()
        options.embedMetadata = metadata
        options.sponsorBlockMark = sponsors
        for audioOnly in [false, true] {
            let arguments = options.arguments(
                quality: .compatible, site: .youtube,
                task: .init(audioOnly: audioOnly, section: try .init(start: "0", end: "8"))
            )
            #expect(!arguments.contains("--embed-chapters"))
            #expect(!arguments.contains("--sponsorblock-mark"))
            #expect(arguments.contains("--no-embed-chapters"))
            #expect(arguments.contains("--embed-metadata") == metadata)
            #expect(Array(arguments.suffix(2)) == ["--download-sections", "*0-8"])
        }
    }

    @Test(arguments: YtDlpOutputOptions.SubtitleMode.allCases)
    func subtitleCleanupOnlyRemovesSelectedRegularFilesOwnedByTheJob(mode: YtDlpOutputOptions.SubtitleMode) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let stem = id + "-Example"
        let video = root.appendingPathComponent(stem + ".mp4")
        try Data("video".utf8).write(to: video)
        let removable = [stem + ".en.vtt", stem + ".en.srt", stem + ".en.ass"]
        let retained = ["other.en.vtt", stem + ".en.danmaku.ass", stem + ".danmaku.ass", stem + ".fr.vtt", stem + ".en.txt"]
        for name in removable + retained { try Data("example".utf8).write(to: root.appendingPathComponent(name)) }
        let link = root.appendingPathComponent(stem + ".ja.vtt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("other.en.vtt"))
        let directory = root.appendingPathComponent(stem + ".zh.vtt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let job = YtDlpJob(id: id, url: video, site: .other, directory: root, name: "Example")

        try YtDlpFileSafety.removeEmbeddedSubtitles(for: job, video: video, languages: ["en", "ja", "zh"], mode: mode)

        for name in removable { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) == (mode != .embed)) }
        for name in retained { #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: video.path))
    }

    @Test(arguments: [false, true])
    func cleanupKeepsBilibiliAndAudioSidecars(audioOnly: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let video = root.appendingPathComponent(id + "-Example.mp4")
        let subtitle = root.appendingPathComponent(id + "-Example.en.vtt")
        try Data("subtitle".utf8).write(to: subtitle)
        let job = YtDlpJob(id: id, url: video, site: audioOnly ? .other : .bilibili, directory: root,
                             name: "Example", outputOptions: .init(audioOnly: audioOnly))
        try YtDlpFileSafety.removeEmbeddedSubtitles(for: job, video: video, languages: ["en"], mode: .embed)
        #expect(FileManager.default.fileExists(atPath: subtitle.path))
    }

    @Test func cleanupRejectsForeignVideoAndReportsMissingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID().uuidString.lowercased()
        let video = root.appendingPathComponent(id + "-Example.mp4")
        let job = YtDlpJob(id: id, url: video, site: .other, directory: root, name: "Example")
        try YtDlpFileSafety.removeEmbeddedSubtitles(for: job, video: root.appendingPathComponent("foreign.mp4"), languages: ["en"], mode: .embed)
        #expect(throws: (any Error).self) {
            try YtDlpFileSafety.removeEmbeddedSubtitles(for: job, video: video, languages: ["en"], mode: .embed)
        }
    }

}
