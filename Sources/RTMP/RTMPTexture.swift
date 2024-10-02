
import Foundation
import AVFoundation
import SwiftUI
import RealityKit
import Metal
import MetalKit
import Spatial

import CoreGraphics
import Accelerate

public final class RTMPTexture: HKStreamOutput {
    private var textureCache: CVMetalTextureCache?
    public let device: (any MTLDevice)?
    private var commandQueue: (any MTLCommandQueue)?
    private var onUpdateMetal:((any MTLTexture)->Void)?
    private var onUpdateImage:((CGImage)->Void)?
    private var onUpdateTextureResource:((TextureResource)->Void)?
    private var isUpdating: Bool = false
    public var currentTexture: (any MTLTexture)?
    public var textureResource: TextureResource?

    public var texture: (any MTLTexture)? {
        return currentTexture
    }
    
    public init(device: any MTLDevice) {
        self.device = device
        self.textureCache = nil
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, self.device!, nil, &textureCache)
    }
    
    public convenience init(device:any MTLDevice, onUpdateTextureResource:@escaping (TextureResource)->Void) {
        self.init(device: device)
        self.onUpdateTextureResource = onUpdateTextureResource
    }
    
    public convenience init(device:any MTLDevice, onUpdateImage:@escaping (CGImage)->Void) {
        self.init(device: device)
        self.onUpdateImage = onUpdateImage
    }
    
    public convenience init(device:any MTLDevice, onUpdateMetal:@escaping (any MTLTexture)->Void) {
        self.init(device: device)
        self.onUpdateMetal = onUpdateMetal
    }
    
    nonisolated public func stream(_ stream: some HKStream, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
    }
    
    nonisolated public func stream(_ stream: some HKStream, didOutput video: CMSampleBuffer) {
        //guard let pixelBuffer = CMSampleBufferGetImageBuffer(video) else { return }
        guard let pixelBuffer = try? CMSampleBufferGetImageBuffer(video)?.toBGRA() else { return }
        guard let textureCache = textureCache else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvMetalTexture: CVMetalTexture? = nil
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, .rgba8Unorm, width, height, 0, &cvMetalTexture)
        
        guard let cvMetalTexture = cvMetalTexture, let metalTexture = CVMetalTextureGetTexture(cvMetalTexture) else {
            return
        }

        if self.currentTexture == nil {
            let textureDescriptor = MTLTextureDescriptor
                .texture2DDescriptor(pixelFormat: metalTexture.pixelFormat,
                                     width: metalTexture.width,
                                     height: metalTexture.height,
                                     mipmapped: false)
            textureDescriptor.usage = .unknown
            self.currentTexture = device!.makeTexture(descriptor: textureDescriptor)
        }
 
        //self.currentTexture = metalTexture
        
        if self.commandQueue == nil {
            self.commandQueue = device!.makeCommandQueue()
        }
        
        guard let commandQueue = self.commandQueue else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        guard let currentTexture = self.currentTexture else { return }
        
        blitEncoder.copy(from: metalTexture,
                         sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSizeMake(metalTexture.width, metalTexture.height, metalTexture.depth),
                         to: currentTexture, destinationSlice: 0, destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))

        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if self.currentTexture != nil {
            self.onUpdateMetal?(self.currentTexture!)
            
            if self.onUpdateTextureResource != nil && !isUpdating {
                Task { @MainActor in
                    makeTextureResource(mtlTexture: self.currentTexture!)
                }
            }
            
            if self.onUpdateImage != nil {
                Task { @MainActor in
                    if let image = makeImage(for: self.currentTexture!) {
                        onUpdateImage?(image)
                    }
                }
            }
        }
    }
    
    public func makeTextureResource(mtlTexture:any MTLTexture) {
        
        isUpdating = true
        defer {
            isUpdating = false
        }
        
        if textureResource == nil {
            let cgImage = createOnePixelCGImage()
            textureResource = try? .generate(from: cgImage!, options: .init(semantic: .color))
            self.onUpdateTextureResource?(textureResource!)
        }
        
        guard let textureResource = textureResource else { return }
        guard let device = device else { return }
        guard let commandQueue = commandQueue else { return }
        
        print("texture: \(mtlTexture.width) \(mtlTexture.height )")
        let drawableQueue = try! TextureResource.DrawableQueue(.init(pixelFormat: .rgba8Unorm, width: mtlTexture.width, height: mtlTexture.height, usage: [.renderTarget, .shaderRead], mipmapsMode: .none))
        textureResource.replace(withDrawables: drawableQueue)
        
        
        var drawable: TextureResource.Drawable? = nil
        do {
            drawable = try drawableQueue.nextDrawable()
        } catch {
            print(error)
            return
        }
        
        print("drawable update")
        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder()!
        
        blitCommandEncoder.copy(from: mtlTexture, to: drawable!.texture)
        blitCommandEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        drawable!.present()
    }
    
    func createOnePixelCGImage() -> CGImage? {
        // ピクセルデータ: RGBの1ピクセルを指定 (例えば赤色のピクセル)
        let pixelData: [UInt8] = [255, 0, 0, 255] // R, G, B, A (RGBAで赤色)

        // 1ピクセルの幅と高さ
        let width = 1
        let height = 1

        // 色空間
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 各コンポーネントのビット数 (RGBAは8ビット)
        let bitsPerComponent = 8
        let bytesPerRow = 4 * width

        // ビットマップコンテキストを作成
        if let context = CGContext(
            data: UnsafeMutableRawPointer(mutating: pixelData),
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue // RGBAの順番
        ) {
            // CGImageをコンテキストから作成
            return context.makeImage()
        }

        return nil
    }
    
    func makeImage(for texture: any MTLTexture) -> CGImage? {
        assert(texture.pixelFormat == .bgra8Unorm)

        let width = texture.width
        let height = texture.height
        let pixelByteCount = 4 * MemoryLayout<UInt8>.size
        let imageBytesPerRow = width * pixelByteCount
        let imageByteCount = imageBytesPerRow * height
        let imageBytes = UnsafeMutableRawPointer.allocate(byteCount: imageByteCount, alignment: pixelByteCount)
        defer {
            imageBytes.deallocate()
        }

        texture.getBytes(imageBytes,
                         bytesPerRow: imageBytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let bitmapContext = CGContext(data: nil,
                                            width: width,
                                            height: height,
                                            bitsPerComponent: 8,
                                            bytesPerRow: imageBytesPerRow,
                                            space: colorSpace,
                                            bitmapInfo: bitmapInfo) else { return nil }
        bitmapContext.data?.copyMemory(from: imageBytes, byteCount: imageByteCount)
        let image = bitmapContext.makeImage()
        return image
    }
    
}

extension CVPixelBuffer {
    public func toBGRA() throws -> CVPixelBuffer? {
        
        var pixelBuffer = self

        /// Check format
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        //print("pixel format : ", pixelFormat)
        //debugPixelFormatType(pixelFormat: pixelFormat)
        
        if pixelFormat == kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange {
            if let decodedPixelBuffer = decodeLosslessYUVToPixelBuffer(pixelBuffer) {
                pixelBuffer = decodedPixelBuffer
            }
        }

        /// Split plane
        let yImage: VImage = pixelBuffer.with({ VImage(pixelBuffer: $0, plane: 0) })!
        let cbcrImage: VImage = pixelBuffer.with({ VImage(pixelBuffer: $0, plane: 1) })!

        /// Create output pixelBuffer
        guard let outPixelBuffer = CVPixelBuffer.make(width: yImage.width, height: yImage.height, format: kCVPixelFormatType_32BGRA) else { return nil }
        
        /// Convert yuv to argb
        var argbImage = outPixelBuffer.with({ VImage(pixelBuffer: $0) })!
        try argbImage.draw(yBuffer: yImage.buffer, cbcrBuffer: cbcrImage.buffer)
        
        /// Convert argb to bgra
        argbImage.permute(channelMap: [3, 2, 1, 0])

        return outPixelBuffer
    }
}

struct VImage {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    var buffer: vImage_Buffer

    init?(pixelBuffer: CVPixelBuffer, plane: Int) {
        guard let rawBuffer = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { return nil }
        self.width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        self.height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        self.bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        self.buffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: rawBuffer),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
    }

    init?(pixelBuffer: CVPixelBuffer) {
        guard let rawBuffer = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
        self.bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        self.buffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: rawBuffer),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
    }

    mutating func draw(yBuffer: vImage_Buffer, cbcrBuffer: vImage_Buffer) throws {
        try buffer.draw(yBuffer: yBuffer, cbcrBuffer: cbcrBuffer)
    }

    mutating func permute(channelMap: [UInt8]) {
        buffer.permute(channelMap: channelMap)
    }
}

extension CVPixelBuffer {
    func with<T>(_ closure: ((_ pixelBuffer: CVPixelBuffer) -> T)) -> T {
        CVPixelBufferLockBaseAddress(self, .readOnly)
        let result = closure(self)
        CVPixelBufferUnlockBaseAddress(self, .readOnly)
        return result
    }

    static func make(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer? = nil
        CVPixelBufferCreate(kCFAllocatorDefault,
                            width,
                            height,
                            format,
                            [String(kCVPixelBufferIOSurfacePropertiesKey): [
                                "IOSurfaceOpenGLESFBOCompatibility": true,
                                "IOSurfaceOpenGLESTextureCompatibility": true,
                                "IOSurfaceCoreAnimationCompatibility": true,
                            ]] as CFDictionary,
                            &pixelBuffer)
        return pixelBuffer
    }
}

extension vImage_Buffer {
    mutating func draw(yBuffer: vImage_Buffer, cbcrBuffer: vImage_Buffer) throws {
        var yBuffer = yBuffer
        var cbcrBuffer = cbcrBuffer
        var conversionMatrix: vImage_YpCbCrToARGB = {
            var pixelRange = vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 1, CbCrMax: 255, CbCrMin: 0)
            var matrix = vImage_YpCbCrToARGB()
            vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &pixelRange, &matrix, kvImage420Yp8_CbCr8, kvImageARGB8888, UInt32(kvImageNoFlags))
            return matrix
        }()
        let error = vImageConvert_420Yp8_CbCr8ToARGB8888(&yBuffer, &cbcrBuffer, &self, &conversionMatrix, nil, 255, UInt32(kvImageNoFlags))
        if error != kvImageNoError {
            fatalError()
        }
    }

    mutating func permute(channelMap: [UInt8]) {
        vImagePermuteChannels_ARGB8888(&self, &self, channelMap, 0)
    }
}


func decodeLosslessYUVToPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()

    // 未圧縮のピクセルバッファを作成
    var outputPixelBuffer: CVPixelBuffer?
    let attributes: CFDictionary = [
        kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        kCVPixelBufferWidthKey: CVPixelBufferGetWidth(pixelBuffer),
        kCVPixelBufferHeightKey: CVPixelBufferGetHeight(pixelBuffer)
    ] as CFDictionary
    
    CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &outputPixelBuffer)
    
    // CIContextで圧縮解除し、未圧縮のピクセルバッファに書き込み
    guard let outputBuffer = outputPixelBuffer else {
        return nil
    }
    context.render(ciImage, to: outputBuffer)
    
    return outputBuffer
}


func debugPixelFormatType(pixelFormat: OSType) {
    switch pixelFormat {
    case kCVPixelFormatType_1Monochrome:
        print("PixelFormat: kCVPixelFormatType_1Monochrome")
    case kCVPixelFormatType_2Indexed:
        print("PixelFormat: kCVPixelFormatType_2Indexed")
    case kCVPixelFormatType_4Indexed:
        print("PixelFormat: kCVPixelFormatType_4Indexed")
    case kCVPixelFormatType_8Indexed:
        print("PixelFormat: kCVPixelFormatType_8Indexed")
    case kCVPixelFormatType_1IndexedGray_WhiteIsZero:
        print("PixelFormat: kCVPixelFormatType_1IndexedGray_WhiteIsZero")
    case kCVPixelFormatType_2IndexedGray_WhiteIsZero:
        print("PixelFormat: kCVPixelFormatType_2IndexedGray_WhiteIsZero")
    case kCVPixelFormatType_4IndexedGray_WhiteIsZero:
        print("PixelFormat: kCVPixelFormatType_4IndexedGray_WhiteIsZero")
    case kCVPixelFormatType_8IndexedGray_WhiteIsZero:
        print("PixelFormat: kCVPixelFormatType_8IndexedGray_WhiteIsZero")
    case kCVPixelFormatType_16BE555:
        print("PixelFormat: kCVPixelFormatType_16BE555")
    case kCVPixelFormatType_16LE555:
        print("PixelFormat: kCVPixelFormatType_16LE555")
    case kCVPixelFormatType_16LE5551:
        print("PixelFormat: kCVPixelFormatType_16LE5551")
    case kCVPixelFormatType_16BE565:
        print("PixelFormat: kCVPixelFormatType_16BE565")
    case kCVPixelFormatType_16LE565:
        print("PixelFormat: kCVPixelFormatType_16LE565")
    case kCVPixelFormatType_24RGB:
        print("PixelFormat: kCVPixelFormatType_24RGB")
    case kCVPixelFormatType_24BGR:
        print("PixelFormat: kCVPixelFormatType_24BGR")
    case kCVPixelFormatType_32ARGB:
        print("PixelFormat: kCVPixelFormatType_32ARGB")
    case kCVPixelFormatType_32BGRA:
        print("PixelFormat: kCVPixelFormatType_32BGRA")
    case kCVPixelFormatType_32ABGR:
        print("PixelFormat: kCVPixelFormatType_32ABGR")
    case kCVPixelFormatType_32RGBA:
        print("PixelFormat: kCVPixelFormatType_32RGBA")
    case kCVPixelFormatType_64ARGB:
        print("PixelFormat: kCVPixelFormatType_64ARGB")
    case kCVPixelFormatType_64RGBALE:
        print("PixelFormat: kCVPixelFormatType_64RGBALE")
    case kCVPixelFormatType_48RGB:
        print("PixelFormat: kCVPixelFormatType_48RGB")
    case kCVPixelFormatType_32AlphaGray:
        print("PixelFormat: kCVPixelFormatType_32AlphaGray")
    case kCVPixelFormatType_16Gray:
        print("PixelFormat: kCVPixelFormatType_16Gray")
    case kCVPixelFormatType_30RGB:
        print("PixelFormat: kCVPixelFormatType_30RGB")
    case kCVPixelFormatType_30RGB_r210:
        print("PixelFormat: kCVPixelFormatType_30RGB_r210")
    case kCVPixelFormatType_422YpCbCr8:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr8")
    case kCVPixelFormatType_4444YpCbCrA8:
        print("PixelFormat: kCVPixelFormatType_4444YpCbCrA8")
    case kCVPixelFormatType_4444YpCbCrA8R:
        print("PixelFormat: kCVPixelFormatType_4444YpCbCrA8R")
    case kCVPixelFormatType_4444AYpCbCr8:
        print("PixelFormat: kCVPixelFormatType_4444AYpCbCr8")
    case kCVPixelFormatType_4444AYpCbCr16:
        print("PixelFormat: kCVPixelFormatType_4444AYpCbCr16")
    case kCVPixelFormatType_4444AYpCbCrFloat:
        print("PixelFormat: kCVPixelFormatType_4444AYpCbCrFloat")
    case kCVPixelFormatType_444YpCbCr8:
        print("PixelFormat: kCVPixelFormatType_444YpCbCr8")
    case kCVPixelFormatType_422YpCbCr16:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr16")
    case kCVPixelFormatType_422YpCbCr10:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr10")
    case kCVPixelFormatType_444YpCbCr10:
        print("PixelFormat: kCVPixelFormatType_444YpCbCr10")
    case kCVPixelFormatType_420YpCbCr8Planar:
        print("PixelFormat: kCVPixelFormatType_420YpCbCr8Planar")
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_420YpCbCr8PlanarFullRange")
    case kCVPixelFormatType_422YpCbCr_4A_8BiPlanar:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr_4A_8BiPlanar")
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange")
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange")
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange")
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr8BiPlanarFullRange")
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange")
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange")
    case kCVPixelFormatType_422YpCbCr8_yuvs:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr8_yuvs")
    case kCVPixelFormatType_422YpCbCr8FullRange:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr8FullRange")
    case kCVPixelFormatType_OneComponent8:
        print("PixelFormat: kCVPixelFormatType_OneComponent8")
    case kCVPixelFormatType_TwoComponent8:
        print("PixelFormat: kCVPixelFormatType_TwoComponent8")
    case kCVPixelFormatType_30RGBLEPackedWideGamut:
        print("PixelFormat: kCVPixelFormatType_30RGBLEPackedWideGamut")
    case kCVPixelFormatType_ARGB2101010LEPacked:
        print("PixelFormat: kCVPixelFormatType_ARGB2101010LEPacked")
    case kCVPixelFormatType_40ARGBLEWideGamut:
        print("PixelFormat: kCVPixelFormatType_40ARGBLEWideGamut")
    case kCVPixelFormatType_40ARGBLEWideGamutPremultiplied:
        print("PixelFormat: kCVPixelFormatType_40ARGBLEWideGamutPremultiplied")
    case kCVPixelFormatType_OneComponent10:
        print("PixelFormat: kCVPixelFormatType_OneComponent10")
    case kCVPixelFormatType_OneComponent12:
        print("PixelFormat: kCVPixelFormatType_OneComponent12")
    case kCVPixelFormatType_OneComponent16:
        print("PixelFormat: kCVPixelFormatType_OneComponent16")
    case kCVPixelFormatType_TwoComponent16:
        print("PixelFormat: kCVPixelFormatType_TwoComponent16")
    case kCVPixelFormatType_OneComponent16Half:
        print("PixelFormat: kCVPixelFormatType_OneComponent16Half")
    case kCVPixelFormatType_OneComponent32Float:
        print("PixelFormat: kCVPixelFormatType_OneComponent32Float")
    case kCVPixelFormatType_TwoComponent16Half:
        print("PixelFormat: kCVPixelFormatType_TwoComponent16Half")
    case kCVPixelFormatType_TwoComponent32Float:
        print("PixelFormat: kCVPixelFormatType_TwoComponent32Float")
    case kCVPixelFormatType_64RGBAHalf:
        print("PixelFormat: kCVPixelFormatType_64RGBAHalf")
    case kCVPixelFormatType_128RGBAFloat:
        print("PixelFormat: kCVPixelFormatType_128RGBAFloat")
    case kCVPixelFormatType_14Bayer_GRBG:
        print("PixelFormat: kCVPixelFormatType_14Bayer_GRBG")
    case kCVPixelFormatType_14Bayer_RGGB:
        print("PixelFormat: kCVPixelFormatType_14Bayer_RGGB")
    case kCVPixelFormatType_14Bayer_BGGR:
        print("PixelFormat: kCVPixelFormatType_14Bayer_BGGR")
    case kCVPixelFormatType_14Bayer_GBRG:
        print("PixelFormat: kCVPixelFormatType_14Bayer_GBRG")
    case kCVPixelFormatType_DisparityFloat16:
        print("PixelFormat: kCVPixelFormatType_DisparityFloat16")
    case kCVPixelFormatType_DisparityFloat32:
        print("PixelFormat: kCVPixelFormatType_DisparityFloat32")
    case kCVPixelFormatType_DepthFloat16:
        print("PixelFormat: kCVPixelFormatType_DepthFloat16")
    case kCVPixelFormatType_DepthFloat32:
        print("PixelFormat: kCVPixelFormatType_DepthFloat32")
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange")
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange")
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange")
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange")
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarFullRange")
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange")
    case kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar:
        print("PixelFormat: kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar")
    case kCVPixelFormatType_16VersatileBayer:
        print("PixelFormat: kCVPixelFormatType_16VersatileBayer")
    case kCVPixelFormatType_64RGBA_DownscaledProResRAW:
        print("PixelFormat: kCVPixelFormatType_64RGBA_DownscaledProResRAW")
    case kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange")
    case kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange")
    case kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar:
        print("PixelFormat: kCVPixelFormatType_444YpCbCr16VideoRange_16A_TriPlanar")
    case kCVPixelFormatType_Lossless_32BGRA:
        print("PixelFormat: kCVPixelFormatType_Lossless_32BGRA")
    case kCVPixelFormatType_Lossless_64RGBAHalf:
        print("PixelFormat: kCVPixelFormatType_Lossless_64RGBAHalf")
    case kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange")
    case kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange")
    case kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange")
    case kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_Lossless_422YpCbCr10PackedBiPlanarVideoRange")
    case kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange")
    case kCVPixelFormatType_Lossy_32BGRA:
        print("PixelFormat: kCVPixelFormatType_Lossy_32BGRA")
    case kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarVideoRange")
    case kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange:
        print("PixelFormat: kCVPixelFormatType_Lossy_420YpCbCr8BiPlanarFullRange")
    case kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_Lossy_420YpCbCr10PackedBiPlanarVideoRange")
    case kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange:
        print("PixelFormat: kCVPixelFormatType_Lossy_422YpCbCr10PackedBiPlanarVideoRange")
    default:
        print("Unknown PixelFormat: \(pixelFormat)")
    }
}
