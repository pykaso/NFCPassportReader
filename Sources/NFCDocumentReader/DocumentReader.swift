//
//  DocumentReader.swift
//  NFCTest
//
//  Created by Andy Qua on 11/06/2019.
//  Copyright © 2019 Andy Qua. All rights reserved.
//

import Foundation

#if !os(macOS)
    import CoreNFC
    import UIKit

    @available(iOS 13, *)
    public class DocumentReader: NSObject {
        private typealias NFCCheckedContinuation = CheckedContinuation<NFCDocumentModel, Error>
        private var nfcContinuation: NFCCheckedContinuation?

        private var document: NFCDocumentModel = NFCDocumentModel()

        private var readerSession: NFCTagReaderSession?
        private var currentlyReadingDataGroup: DataGroupId?

        private var dataGroupsToRead: [DataGroupId] = []
        private var readAllDatagroups = false
        private var skipSecureElements = true
        private var skipCA = false
        private var skipPACE = false

        private var bacHandler: BACHandler?
        private var caHandler: ChipAuthenticationHandler?
        private var paceHandler: PACEHandler?
        private var mrzKey: String = ""
        private var dataAmountToReadOverride: Int?

        private var scanCompletedHandler: ((NFCDocumentModel?, NFCDocumentReaderError?) -> Void)!
        private var nfcViewDisplayMessageHandler: ((NFCViewDisplayMessage) -> String?)?
        private var masterListURL: URL?
        private var shouldNotReportNextReaderSessionInvalidationErrorUserCanceled: Bool = false

        // By default, Passive Authentication uses the new RFS5652 method to verify the SOD, but can be switched to use
        // the previous OpenSSL CMS verification if necessary
        public var passiveAuthenticationUsesOpenSSL: Bool = false

        public init(logLevel: LogLevel = .info, masterListURL: URL? = nil) {
            super.init()

            Log.logLevel = logLevel
            self.masterListURL = masterListURL
        }

        public func setMasterListURL(_ masterListURL: URL) {
            self.masterListURL = masterListURL
        }

        // This function allows you to override the amount of data the TagReader tries to read from the NFC
        // chip. NOTE - this really shouldn't be used for production but is useful for testing as different
        // docuemnts support different data amounts.
        // It appears that the most reliable is 0xA0 (160 chars) but some will support arbitary reads (0xFF or 256)
        public func overrideNFCDataAmountToRead(amount: Int) {
            dataAmountToReadOverride = amount
        }

        public func readDocument(mrzKey: String, tags: [DataGroupId] = [], skipSecureElements: Bool = true, skipCA: Bool = false, skipPACE: Bool = false, customDisplayMessage: ((NFCViewDisplayMessage) -> String?)? = nil) async throws -> NFCDocumentModel {
            document = NFCDocumentModel()
            self.mrzKey = mrzKey
            self.skipCA = skipCA
            self.skipPACE = skipPACE

            dataGroupsToRead.removeAll()
            dataGroupsToRead.append(contentsOf: tags)
            nfcViewDisplayMessageHandler = customDisplayMessage
            self.skipSecureElements = skipSecureElements
            currentlyReadingDataGroup = nil
            bacHandler = nil
            caHandler = nil
            paceHandler = nil

            // If no tags specified, read all
            if dataGroupsToRead.count == 0 {
                // Start off with .COM, will always read (and .SOD but we'll add that after), and then add the others from the COM
                dataGroupsToRead.append(contentsOf: [.COM, .SOD])
                readAllDatagroups = true
            } else {
                // We are reading specific datagroups
                readAllDatagroups = false
            }

            guard NFCNDEFReaderSession.readingAvailable else {
                throw NFCDocumentReaderError.NFCNotSupported
            }

            if NFCTagReaderSession.readingAvailable {
                readerSession = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil)

                updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.requestPresentDocument)
                readerSession?.begin()
            }

            return try await withCheckedThrowingContinuation({ (continuation: NFCCheckedContinuation) in
                self.nfcContinuation = continuation
            })
        }
    }

    @available(iOS 13, *)
    extension DocumentReader: NFCTagReaderSessionDelegate {
        // MARK: - NFCTagReaderSessionDelegate

        public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
            // If necessary, you may perform additional operations on session start.
            // At this point RF polling is enabled.
            Log.debug("tagReaderSessionDidBecomeActive")
        }

        public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
            // If necessary, you may handle the error. Note session is no longer valid.
            // You must create a new session to restart RF polling.
            Log.debug("tagReaderSession:didInvalidateWithError - \(error.localizedDescription)")
            readerSession?.invalidate()
            readerSession = nil

            if let readerError = error as? NFCReaderError, readerError.code == NFCReaderError.readerSessionInvalidationErrorUserCanceled
                && self.shouldNotReportNextReaderSessionInvalidationErrorUserCanceled {
                shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = false
            } else {
                var userError = NFCDocumentReaderError.UnexpectedError
                if let readerError = error as? NFCReaderError {
                    Log.error("tagReaderSession:didInvalidateWithError - Got NFCReaderError - \(readerError.localizedDescription)")
                    switch readerError.code {
                    case NFCReaderError.readerSessionInvalidationErrorUserCanceled:
                        Log.error("     - User cancelled session")
                        userError = NFCDocumentReaderError.UserCanceled
                    default:
                        Log.error("     - some other error - \(readerError.localizedDescription)")
                        userError = NFCDocumentReaderError.UnexpectedError
                    }
                } else {
                    Log.error("tagReaderSession:didInvalidateWithError - Received error - \(error.localizedDescription)")
                }
                nfcContinuation?.resume(throwing: userError)
                nfcContinuation = nil
            }
        }

        public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
            Log.debug("tagReaderSession:didDetect - \(tags[0])")
            if tags.count > 1 {
                Log.debug("tagReaderSession:more than 1 tag detected! - \(tags)")

                let errorMessage = NFCViewDisplayMessage.error(.MoreThanOneTagFound)
                invalidateSession(errorMessage: errorMessage, error: NFCDocumentReaderError.MoreThanOneTagFound)
                return
            }

            let tag = tags.first!
            var documentTag: NFCISO7816Tag
            switch tags.first! {
            case let .iso7816(tag):
                documentTag = tag
            default:
                Log.debug("tagReaderSession:invalid tag detected!!!")

                let errorMessage = NFCViewDisplayMessage.error(NFCDocumentReaderError.TagNotValid)
                invalidateSession(errorMessage: errorMessage, error: NFCDocumentReaderError.TagNotValid)
                return
            }

            Task { [documentTag] in
                do {
                    try await session.connect(to: tag)

                    Log.debug("tagReaderSession:connected to tag - starting authentication")
                    self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.authenticatingWithDocument(0))

                    let tagReader = TagReader(tag: documentTag)

                    if let newAmount = self.dataAmountToReadOverride {
                        tagReader.overrideDataAmountToRead(newAmount: newAmount)
                    }

                    tagReader.progress = { [unowned self] progress in
                        if let dgId = self.currentlyReadingDataGroup {
                            self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.readingDataGroupProgress(dgId, progress))
                        } else {
                            self.updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.authenticatingWithDocument(progress))
                        }
                    }

                    let documentModel = try await self.startReading(tagReader: tagReader)
                    nfcContinuation?.resume(returning: documentModel)
                    nfcContinuation = nil

                } catch let error as NFCDocumentReaderError {
                    let errorMessage = NFCViewDisplayMessage.error(error)
                    self.invalidateSession(errorMessage: errorMessage, error: error)
                } catch let error {
                    nfcContinuation?.resume(throwing: error)
                    nfcContinuation = nil
                    Log.debug("tagReaderSession:failed to connect to tag - \(error.localizedDescription)")
                    let errorMessage = NFCViewDisplayMessage.error(NFCDocumentReaderError.ConnectionError)
                    self.invalidateSession(errorMessage: errorMessage, error: NFCDocumentReaderError.ConnectionError)
                }
            }
        }

        func updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage) {
            readerSession?.alertMessage = nfcViewDisplayMessageHandler?(alertMessage) ?? alertMessage.description
        }
    }

    @available(iOS 13, *)
    extension DocumentReader {
        func startReading(tagReader: TagReader) async throws -> NFCDocumentModel {
            if !skipPACE {
                do {
                    let data = try await tagReader.readCardAccess()
                    Log.verbose("Read CardAccess - data \(binToHexRep(data))")
                    let cardAccess = try CardAccess(data)
                    document.cardAccess = cardAccess

                    Log.info("Starting Password Authenticated Connection Establishment (PACE)")

                    let paceHandler = try PACEHandler(cardAccess: cardAccess, tagReader: tagReader)
                    try await paceHandler.doPACE(mrzKey: mrzKey)
                    document.PACEStatus = .success
                    Log.debug("PACE Succeeded")
                } catch {
                    document.PACEStatus = .failed
                    Log.error("PACE Failed - falling back to BAC")
                }

                _ = try await tagReader.selectDocumentApplication()
            }

            // If either PACE isn't supported, we failed whilst doing PACE or we didn't even attempt it, then fall back to BAC
            if document.PACEStatus != .success {
                try await doBACAuthentication(tagReader: tagReader)
            }

            // Now to read the datagroups
            try await readDataGroups(tagReader: tagReader)

            updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.successfulRead)

            try await doActiveAuthenticationIfNeccessary(tagReader: tagReader)
            shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = true
            readerSession?.invalidate()

            // If we have a masterlist url set then use that and verify the document now
            document.verifyDocument(masterListURL: masterListURL, useCMSVerification: passiveAuthenticationUsesOpenSSL)

            return document
        }

        func doActiveAuthenticationIfNeccessary(tagReader: TagReader) async throws {
            guard document.activeAuthenticationSupported else {
                return
            }

            Log.info("Performing Active Authentication")

            let challenge = generateRandomUInt8Array(8)
            Log.verbose("Generated Active Authentication challange - \(binToHexRep(challenge))")
            let response = try await tagReader.doInternalAuthentication(challenge: challenge)
            document.verifyActiveAuthentication(challenge: challenge, signature: response.data)
        }

        func doBACAuthentication(tagReader: TagReader) async throws {
            currentlyReadingDataGroup = nil

            Log.info("Starting Basic Access Control (BAC)")

            document.BACStatus = .failed

            bacHandler = BACHandler(tagReader: tagReader)
            try await bacHandler?.performBACAndGetSessionKeys(mrzKey: mrzKey)
            Log.info("Basic Access Control (BAC) - SUCCESS!")

            document.BACStatus = .success
        }

        func readDataGroups(tagReader: TagReader) async throws {
            // Read COM
            var DGsToRead = [DataGroupId]()

            updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.readingDataGroupProgress(.COM, 0))
            if let com = try await readDataGroup(tagReader: tagReader, dgId: .COM) as? COM {
                document.addDataGroup(.COM, dataGroup: com)

                // SOD and COM shouldn't be present in the DG list but just in case (worst case here we read the sod twice)
                DGsToRead = [.SOD] + com.dataGroupsPresent.map { DataGroupId.getIDFromName(name: $0) }
                DGsToRead.removeAll { $0 == .COM }
            }

            if DGsToRead.contains(.DG14) {
                DGsToRead.removeAll { $0 == .DG14 }

                if !skipCA {
                    // Do Chip Authentication
                    if let dg14 = try await readDataGroup(tagReader: tagReader, dgId: .DG14) as? DataGroup14 {
                        document.addDataGroup(.DG14, dataGroup: dg14)
                        let caHandler = ChipAuthenticationHandler(dg14: dg14, tagReader: tagReader)

                        if caHandler.isChipAuthenticationSupported {
                            do {
                                // Do Chip authentication and then continue reading datagroups
                                try await caHandler.doChipAuthentication()
                                document.chipAuthenticationStatus = .success
                            } catch {
                                Log.info("Chip Authentication failed - re-establishing BAC")
                                document.chipAuthenticationStatus = .failed

                                // Failed Chip Auth, need to re-establish BAC
                                try await doBACAuthentication(tagReader: tagReader)
                            }
                        }
                    }
                }
            }

            // If we are skipping secure elements then remove .DG3 and .DG4
            if skipSecureElements {
                DGsToRead = DGsToRead.filter { $0 != .DG3 && $0 != .DG4 }
            }

            if readAllDatagroups != true {
                DGsToRead = DGsToRead.filter { dataGroupsToRead.contains($0) }
            }
            for dgId in DGsToRead {
                updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.readingDataGroupProgress(dgId, 0))
                if let dg = try await readDataGroup(tagReader: tagReader, dgId: dgId) {
                    document.addDataGroup(dgId, dataGroup: dg)
                }
            }
        }

        func readDataGroup(tagReader: TagReader, dgId: DataGroupId) async throws -> DataGroup? {
            currentlyReadingDataGroup = dgId
            Log.info("Reading tag - \(dgId)")
            var readAttempts = 0

            updateReaderSessionMessage(alertMessage: NFCViewDisplayMessage.readingDataGroupProgress(dgId, 0))

            repeat {
                do {
                    let response = try await tagReader.readDataGroup(dataGroup: dgId)
                    let dg = try DataGroupParser().parseDG(data: response)
                    return dg
                } catch let error as NFCDocumentReaderError {
                    Log.error("TagError reading tag - \(error)")

                    // OK we had an error - depending on what happened, we may want to try to re-read this
                    // E.g. we failed to read the last Datagroup because its protected and we can't
                    let errMsg = error.value
                    Log.error("ERROR - \(errMsg)")

                    var redoBAC = false
                    if errMsg == "Session invalidated" || errMsg == "Class not supported" || errMsg == "Tag connection lost" {
                        // Check if we have done Chip Authentication, if so, set it to nil and try to redo BAC
                        if self.caHandler != nil {
                            self.caHandler = nil
                            redoBAC = true
                        } else {
                            // Can't go any more!
                            throw error
                        }
                    } else if errMsg == "Security status not satisfied" || errMsg == "File not found" {
                        // Can't read this element as we aren't allowed - remove it and return out so we re-do BAC
                        self.dataGroupsToRead.removeFirst()
                        redoBAC = true
                    } else if errMsg == "SM data objects incorrect" || errMsg == "Class not supported" {
                        // Can't read this element security objects now invalid - and return out so we re-do BAC
                        redoBAC = true
                    } else if errMsg.hasPrefix("Wrong length") || errMsg.hasPrefix("End of file") { // Should now handle errors 0x6C xx, and 0x67 0x00
                        // OK passport can't handle max length so drop it down
                        tagReader.reduceDataReadingAmount()
                        redoBAC = true
                    }

                    if redoBAC {
                        // Redo BAC and try again
                        try await doBACAuthentication(tagReader: tagReader)
                    } else {
                        // Some other error lets have another try
                    }
                }
                readAttempts += 1
            } while readAttempts < 2

            return nil
        }

        func invalidateSession(errorMessage: NFCViewDisplayMessage, error: NFCDocumentReaderError) {
            // Mark the next 'invalid session' error as not reportable (we're about to cause it by invalidating the
            // session). The real error is reported back with the call to the completed handler
            shouldNotReportNextReaderSessionInvalidationErrorUserCanceled = true
            readerSession?.invalidate(errorMessage: nfcViewDisplayMessageHandler?(errorMessage) ?? errorMessage.description)
            nfcContinuation?.resume(throwing: error)
            nfcContinuation = nil
        }
    }
#endif
