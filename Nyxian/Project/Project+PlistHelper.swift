//
//  Project+PlistHelper.swift
//  LindDE
//
//  Created by fridakitten on 08.05.25.
//

import Foundation

class PlistHelper {
    var plistPath: String
    var savedModificationDate: Date
    var lastModificationDate: Date {
        get {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: plistPath) else { return Date() }
            guard let modDate = attributes[.modificationDate] as? Date else { return Date() }
            return modDate
        }
    }
    
    var onReload: ([String:Any]) -> Void = { _ in }
    
    init(plistPath: String) {
        self.plistPath = plistPath
        self.savedModificationDate = Date()
        
        self.savedModificationDate = self.lastModificationDate
    }
    
    @discardableResult func reloadIfNeeded() -> Bool {
        let modDate = self.lastModificationDate
        let needsReload: Bool = self.savedModificationDate < modDate
        if needsReload {
            let dict: [String:Any] = (NSDictionary(contentsOfFile: plistPath) as? [String:Any]) ?? [:]
            onReload(dict)
            self.savedModificationDate = modDate
        }
        return needsReload
    }
    
    func reloadForcefully() {
        let dict: [String:Any] = (NSDictionary(contentsOfFile: plistPath) as? [String:Any]) ?? [:]
        onReload(dict)
        self.savedModificationDate = self.lastModificationDate
    }
    
    func overWritePlist(dict: [String:Any]) {
        NSDictionary(dictionary: dict).write(to: URL(fileURLWithPath: plistPath), atomically: true)
    }
}
