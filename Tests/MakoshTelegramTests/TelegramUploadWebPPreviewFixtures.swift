import Foundation

/// Owned synthetic640x320 RGB quadrants: red/green above blue/yellow.
/// Recipe: stdlib Python PNG(zlib9), cwebp1.6.0 -lossless -exact; no runtime tool dependency.
/// WebP90B SHA2564d6a33066e5a2f0299a8b7d1e297393bcd7a666db3c51630a4838b428a7f47f6.
let uploadWebPLargePreviewFixture = Data(base64Encoded:
    "UklGRlIAAABXRUJQVlA4TEYAAAAvf8JPAB8gEEjaH3qN+RcQFPk/2vwHXyRAUdtG0pAckkNyCPS3hyP6PwEbt+PyH//xH//xH/+dMhV34vIf//Ef//Ef/50y")!
