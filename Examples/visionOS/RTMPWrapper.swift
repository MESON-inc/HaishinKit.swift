


import HaishinKit

@MainActor var connection:RTMPConnection?
@MainActor var stream:RTMPStream?
@MainActor var texture:RTMPTexture?
@MainActor var texturePtr:UnsafeMutableRawPointer?

@_cdecl("connect")
public func connect(url:String, onUpdate:@escaping (UnsafeMutableRawPointer)->Void) {
    Task { @MainActor in
        
        if connection == nil {
            connection = .init()
        }
        if stream == nil {
            stream = .init(connection: connection!)
        }
        if texture == nil {
            texture = .init(onUpdateTextureResource: { texture in
                if texturePtr == nil {
                    texturePtr = Unmanaged.passUnretained(texture).toOpaque()
                }
                onUpdate(texturePtr!)
            })
        }
        
        do {
            let response = try await connection!.connect(url)
            try await stream?.play("live")
        } catch RTMPConnection.Error.requestFailed(let response) {
            logger.warn(response)
        } catch RTMPStream.Error.requestFailed(let response) {
            logger.warn(response)
        } catch {
            logger.warn(error)
        }
    }
}
