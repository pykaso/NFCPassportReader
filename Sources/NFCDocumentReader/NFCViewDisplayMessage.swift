//
//  NFCViewDisplayMessage.swift
//  NFCDocumentReader
//
//  Created by Andy Qua on 09/02/2021.
//

import Foundation

@available(iOS 13, macOS 10.15, *)
public enum NFCViewDisplayMessage {
    case requestPresentDocument
    case authenticatingWithDocument(Int)
    case readingDataGroupProgress(DataGroupId, Int)
    case error(NFCDocumentReaderError)
    case successfulRead
}

@available(iOS 13, macOS 10.15, *)
extension NFCViewDisplayMessage {
    public var description: String {
        switch self {
        case .requestPresentDocument:
            return "Please hold the document to the top of the phone."
        case let .authenticatingWithDocument(progress):
            let progressString = handleProgress(percentualProgress: progress)
            return "Authenticating .....\n\n\(progressString)"
        case let .readingDataGroupProgress(dataGroup, progress):
            let progressString = handleProgress(percentualProgress: progress)
            return "Reading \(dataGroup).....\n\n\(progressString)"
        case let .error(tagError):
            switch tagError {
            case NFCDocumentReaderError.TagNotValid:
                return "Tag not valid."
            case NFCDocumentReaderError.MoreThanOneTagFound:
                return "More than 1 tags was found. Please present only 1 tag."
            case NFCDocumentReaderError.ConnectionError:
                return "Connection error. Please try again."
            case NFCDocumentReaderError.InvalidMRZKey:
                return "MRZ Key not valid for this document."
            case let NFCDocumentReaderError.ResponseError(description, sw1, sw2):
                return "Sorry, there was a problem reading the Document. \(description) - (0x\(sw1), 0x\(sw2)"
            default:
                return "Sorry, there was a problem reading the Document. Please try again"
            }
        case .successfulRead:
            return "NFC read successfully"
        }
    }

    func handleProgress(percentualProgress: Int) -> String {
        let p = (percentualProgress / 20)
        let full = String(repeating: "🔵 ", count: p)
        let empty = String(repeating: "⚪️ ", count: 5 - p)
        return "\(full)\(empty)"
    }
}
