import Foundation
import Vision

/// 画像から OCR でテキストを抽出するサービス。
/// バックグラウンドスレッドで実行し、メインスレッドをブロックしない。
enum OCRService {
    /// 画像ファイルからテキストを抽出する。テキストが見つからなければ nil を返す。
    static func recognizeText(from imageURL: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                let texts = observations.compactMap { $0.topCandidates(1).first?.string }
                let joined = texts.joined(separator: "\n")
                continuation.resume(returning: joined.isEmpty ? nil : joined)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja", "en"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(url: imageURL, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
