// vt_hw_check.swift: whether VideoToolbox reports hardware decode for H.264, HEVC, VP9 and AV1 in a process with a Metal
// device (the NVIDIA plugin registers its decoders when one comes up). `swift vt_hw_check.swift`
import VideoToolbox
import Metal
let d = MTLCreateSystemDefaultDevice(); print("Metal:", d?.name ?? "nil")
Thread.sleep(forTimeInterval: 2)
VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
for (n,c) in [("H264",kCMVideoCodecType_H264),("HEVC",kCMVideoCodecType_HEVC),("VP9",kCMVideoCodecType_VP9),("AV1",kCMVideoCodecType_AV1)] { print(n, VTIsHardwareDecodeSupported(c)) }
