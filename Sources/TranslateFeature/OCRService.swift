import AppKit
import CoreGraphics
import Foundation
import Vision

/// 截图文字识别（Vision 本地 OCR，无需联网与 API 密钥）。
/// 支持中英日韩等；识别结果按视觉顺序逐行拼接。
public enum OCRService {
    /// 识别图像中的全部文字；无文字返回空字符串。
    public static func recognizeText(in image: NSImage) async throws -> String {
        guard let cgImage = cgImage(of: image) else {
            throw TranslationError.ocrFailed("无法读取图像数据")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = [
                    "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR",
                ]
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    let lines = (request.results ?? []).compactMap { observation in
                        observation.topCandidates(1).first?.string
                    }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(throwing: TranslationError.ocrFailed(error.localizedDescription))
                }
            }
        }
    }

    /// NSImage → CGImage（取首选位图表示）。
    private static func cgImage(of image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
