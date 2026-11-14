// SPDX-License-Identifier: MIT
// Copyright (c) 2026 kevineduardo
// avplay <file> <seconds> <8|10> [rate]: plays the file in real time with AVPlayer (as a screen saver or a player does:
// frames are dropped when the decoder cannot keep up) and prints, for each picture the output hands over at a 75 Hz
// poll, its presentation time and the MD5 of every 16th row of its planes in ffmpeg's p010le / nv12 layout (subrow_md5.py
// makes the same digests from a software decode).
import AVFoundation
import CryptoKit
import Metal
_ = MTLCreateSystemDefaultDevice()
let a = CommandLine.arguments
let url = URL(fileURLWithPath: a[1]); let secs = Double(a[2])!; let ten = a[3] == "10"
let rate = a.count > 4 ? Float(a[4])! : 1
let item = AVPlayerItem(url: url)
let fmt = ten ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: fmt])
item.add(out)
let player = AVPlayer(playerItem: item); player.isMuted = true
var shown = 0, lastT = CMTime.invalid
DispatchQueue.global(qos: .userInteractive).async {
    let t0 = Date()
    player.playImmediately(atRate: rate)
    while Date().timeIntervalSince(t0) < secs {
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        if out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &lastT) {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            var h = Insecure.MD5()
            let w = CVPixelBufferGetWidth(pb), ht = CVPixelBufferGetHeight(pb), bps = ten ? 2 : 1
            for p in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, p)!, bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, p)
                let rows = p == 0 ? ht : (ht + 1) / 2, n = (p == 0 ? w : (w + 1) & ~1) * bps
                for y in stride(from: 0, to: rows, by: 16) { h.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * bpr, count: n)) }   // every 16th row: hashing 25 MB a picture took 50 ms and capped the test at 20 pictures a second
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            print(String(format: "%.6f", lastT.seconds), h.finalize().map { String(format: "%02x", $0) }.joined())
            shown += 1
        }
        usleep(4000)
    }
    FileHandle.standardError.write("shown \(shown) pictures in \(secs) s, player rate \(player.rate), status \(item.status.rawValue) \(item.error.map { "\($0)" } ?? "")\n".data(using: .utf8)!)
    exit(0)
}
RunLoop.main.run()
