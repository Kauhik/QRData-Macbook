//
//  QRGenerator.swift
//  QRData Macbook
//
//  Created by Kaushik Manian on 15/9/25.
//

import Foundation

import AppKit
import CoreImage

enum QRGenerator {
    static func makeQR(from string: String, scale: CGFloat = 8) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: transformed)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func savePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "QR", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        try png.write(to: url, options: .atomic)
    }
}
