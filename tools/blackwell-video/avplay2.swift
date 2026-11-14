// SPDX-License-Identifier: MIT
// Copyright (c) 2026 kevineduardo
// avplay2 <clip> <players> <seconds>: `players` AVPlayers of one clip in ONE process, in real time, as the aerial screen
// saver plays one per monitor (realtime.sh runs one process per stream). Prints the pictures each player showed.
// With NVENCVT_LOG=1, "NOT SUPPORTED" or "parse failed" in the log is the shared-parser-state race (fixed: the
// parsers' bit readers are per thread); a run that uses seven cores has fallen back to software decoding.
//   xcrun swiftc -O -o $WORK/avplay2 avplay2.swift && codesign -s - -f $WORK/avplay2
//   NVMTL_PROCESS_ENV=1 NVMTL_NVENCVT=0 NVENCVT_LOG=1 DYLD_INSERT_LIBRARIES=$LIB $WORK/avplay2 clip.mov 2 7.5
import AVFoundation
import Metal
_ = MTLCreateSystemDefaultDevice()
let a = CommandLine.arguments
let n = Int(a[2])!, secs = Double(a[3])!
var keep: [Any] = []
var outs: [AVPlayerItemVideoOutput] = []
for _ in 0..<n {
    let item = AVPlayerItem(url: URL(fileURLWithPath: a[1]))
    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    item.add(out); let p = AVPlayer(playerItem: item); p.isMuted = true; p.play(); keep.append(p); outs.append(out)
}
let t0 = Date(); var shown = [Int](repeating: 0, count: n)
while Date().timeIntervalSince(t0) < secs {
    for (i, o) in outs.enumerated() {
        let t = o.itemTime(forHostTime: CACurrentMediaTime())
        if o.hasNewPixelBuffer(forItemTime: t), o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil { shown[i] += 1 }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
}
print("shown", shown)
