import AVFoundation
import Foundation

/// Cuts one audio file into two at a point in time, for splitting a recording
/// that ran across two meetings. Pure file work, no SwiftData: the caller owns
/// the meeting rows and decides what happens to the original file.
enum AudioSplitter {

    enum SplitError: LocalizedError {
        case cutOutsideFile
        var errorDescription: String? {
            switch self {
            case .cutOutsideFile: "The split point is outside the recording."
            }
        }
    }

    /// Frames copied per read. Small enough that an hour-long call never holds
    /// more than a few hundred KB of samples at once; the exact size is not
    /// performance-tuned.
    private static let chunkFrames: AVAudioFrameCount = 1 << 16

    /// Writes the audio before `time` to `head` and the rest to `tail`. Both
    /// come out as PCM .caf in the source's processing format, which is exactly
    /// how recordings are written in the first place (AudioCaptureManager
    /// writes float32 .caf), so a split recording is byte-for-byte the same
    /// kind of file. A compressed import (m4a, mp3) becomes PCM here; larger on
    /// disk, but lossless from this point and playable everywhere the original
    /// was. The source is left untouched.
    static func split(fileAt source: URL, at time: TimeInterval, head: URL, tail: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let cutFrame = AVAudioFramePosition((time * format.sampleRate).rounded())
        guard cutFrame > 0, cutFrame < input.length else { throw SplitError.cutOutsideFile }

        // Never leave a half-written pair behind on failure.
        do {
            try copy(from: input, frames: 0..<cutFrame, to: head, format: format)
            try copy(from: input, frames: cutFrame..<input.length, to: tail, format: format)
        } catch {
            try? FileManager.default.removeItem(at: head)
            try? FileManager.default.removeItem(at: tail)
            throw error
        }
    }

    private static func copy(from input: AVAudioFile, frames: Range<AVAudioFramePosition>,
                             to url: URL, format: AVAudioFormat) throws {
        let output = try AVAudioFile(forWriting: url, settings: format.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw SplitError.cutOutsideFile
        }
        input.framePosition = frames.lowerBound
        var remaining = frames.upperBound - frames.lowerBound
        while remaining > 0 {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            try input.read(into: buffer, frameCount: want)
            // A short read past what the header promised ends the copy rather
            // than looping forever on zero-length reads.
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    /// Sibling paths for the two halves of `source`: "<stem>_part1.caf" and
    /// "<stem>_part2.caf" in the same folder, numbered past any file already
    /// there so a second split of the same recording cannot overwrite the first.
    static func partURLs(for source: URL) -> (head: URL, tail: URL) {
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        var suffix = ""
        var n = 2
        func candidate(_ part: Int) -> URL {
            dir.appendingPathComponent("\(stem)_part\(part)\(suffix).caf")
        }
        while FileManager.default.fileExists(atPath: candidate(1).path)
                || FileManager.default.fileExists(atPath: candidate(2).path) {
            suffix = "-\(n)"
            n += 1
        }
        return (candidate(1), candidate(2))
    }
}
