/*
 Copyright (C) 2025 SeanIsTethered
 Copyright (C) 2025 Lindsey

 This file is part of Nyxian.

 FridaCodeManager is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 FridaCodeManager is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

import UIKit
import Foundation

class Builder {
    private let project: AppProject
    private let compiler: Compiler
    private let argsString: String
    
    private var dirtySourceFiles: [String] = []
    
    static var abortHandler: () -> Void = {}
    static var _abort: Bool = false
    static var abort: Bool {
        get {
            return _abort
        }
        set {
            _abort = newValue
            abortHandler()
        }
    }
    
    init(project: AppProject) {
        project.projectConfig.plistHelper?.reloadForcefully()
        project.reload()
        
        self.project = project
        
        var genericCompilerFlags: [String] = [
            "-isysroot",
            Bootstrap.shared.bootstrapPath("/SDK/iPhoneOS16.5.sdk"),
            "-I\(Bootstrap.shared.bootstrapPath("/Include/include"))"
        ]
        
        let compilerFlags: [String] = self.project.projectConfig.getCompilerFlags()
        genericCompilerFlags.append(contentsOf: compilerFlags)
        
        self.compiler = Compiler(genericCompilerFlags)
        
        let cachePath = project.getCachePath()
        if !cachePath.0 {
            try? FileManager.default.createDirectory(atPath: cachePath.1, withIntermediateDirectories: false)
        }
        
        try? syncFolderStructure(from: project.getPath().URLGet(), to: cachePath.1.URLGet())
        
        self.dirtySourceFiles = FindFilesStack(self.project.getPath(), ["c","cpp","m","mm"], ["Resources"])
        
        // Check if args have changed
        self.argsString = compilerFlags.joined(separator: " ")
        var fileArgsString: String = ""
        if FileManager.default.fileExists(atPath: "\(cachePath.1)/args.txt") {
            // Check if the args string matches up
            fileArgsString = (try? String(contentsOf: URL(fileURLWithPath: "\(cachePath.1)/args.txt"), encoding: .utf8)) ?? ""
        }
        
        if(fileArgsString == self.argsString), self.project.projectConfig.increment {
            self.dirtySourceFiles = self.dirtySourceFiles.filter { self.isFileDirty($0) }
        }
    }
    
    ///
    /// Function to detect if a file is dirty (has to be recompiled)
    ///
    private func isFileDirty(_ item: String) -> Bool {
        let rpath = relativePath(from: self.project.getPath().URLGet(), to: item.URLGet())
        let objectFilePath = "\(self.project.getCachePath().1)/\(expectedObjectFile(forPath: rpath))"
        
        // Checking if the source file is newer than the compiled object file
        guard let sourceDate = try? FileManager.default
            .attributesOfItem(atPath: item)[.modificationDate] as? Date else {
            return true
        }
        
        guard let objectDate = try? FileManager.default
            .attributesOfItem(atPath: objectFilePath)[.modificationDate] as? Date else {
            return true
        }
        
        if objectDate < sourceDate {
            return true
        }
        
        // Checking if the header files included by the source code are newer than the object file
        let headers: [String] = HeaderIncludationsGatherer(path: item).includes
        for header in headers {
            guard FileManager.default.fileExists(atPath: header),
                let headerDate = try? FileManager.default
                    .attributesOfItem(atPath: header)[.modificationDate] as? Date else {
                return true
            }
            
            if objectDate < headerDate {
                return true
            }
        }
        
        return false
    }
    
    ///
    /// Function to cleanup the project from old build files
    ///
    func clean() throws {
        // first find the files to remove
        let trashfiles: [String] = FindFilesStack(
            project.getPath(),
            ["o","tmp"],
            ["Resources","Config"]
        )
        
        // now remove what was find
        for file in trashfiles {
            try FileManager.default.removeItem(atPath: file)
        }
        
        // if payload exists remove it
        let payloadPath: (Bool,String) = self.project.getPayloadPath()
        
        if(payloadPath.0) {
            try FileManager.default.removeItem(atPath: payloadPath.1)
        }
    }
    
    func prepare() throws {
        // Create bundle path
        try FileManager.default.createDirectory(atPath: self.project.getBundlePath().1, withIntermediateDirectories: true)
        
        // Now copy info dictionary given info dictionary and add/overwrite info
        var infoPlistData: [String:Any] = self.project.projectConfig.infoDictionary
        infoPlistData["CFBundleExecutable"] = self.project.projectConfig.executable
        infoPlistData["CFBundleIdentifier"] = self.project.projectConfig.bundleid
        infoPlistData["CFBundleName"] = self.project.projectConfig.displayname
        infoPlistData["CFBundleShortVersionString"] = self.project.projectConfig.version
        infoPlistData["CFBundleVersion"] = self.project.projectConfig.shortVersion
        infoPlistData["MinimumOSVersion"] = self.project.projectConfig.minimum_version
        
        let infoPlistDataSerialized = try PropertyListSerialization.data(fromPropertyList: infoPlistData, format: .xml, options: 0)
        FileManager.default.createFile(atPath:"\(self.project.getBundlePath().1)/Info.plist", contents: infoPlistDataSerialized, attributes: nil)
        try Builder.isAbortedCheck()
    }
    
    ///
    /// Function to build object files
    ///
    func compile() throws {
        let pstep: Double = 1.00 / Double(self.dirtySourceFiles.count)
        let group: DispatchGroup = DispatchGroup()
        let threader = ThreadDispatchLimiter(threads: self.project.projectConfig.threads)
        
        // Setup abort handler
        Builder.abortHandler = {
            threader.lockdown()
        }
        
        // Now compile
        for _ in self.dirtySourceFiles {
            group.enter()
        }
        
        for filePath in self.dirtySourceFiles {
            threader.spawn {
                let rpath: String = relativePath(from: self.project.getPath().URLGet(), to: filePath.URLGet())
                let eobject = expectedObjectFile(forPath: rpath)
                let outputFilePath = "\(self.project.getCachePath().1)/\(eobject)"
                
                if self.compiler.compileObject(filePath, outputFile: outputFilePath, platformTriple: self.project.projectConfig.minimum_version) != 0 {
                    threader.lockdown()
                    return
                }
                
                XCodeButton.incrementProgress(progress: pstep)
            } completion: {
                group.leave()
            }
        }
        
        group.wait()
        
        // Destroy handler
        Builder.abortHandler = {}
        
        if threader.isLockdown {
            throw NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "[!] failed to compile source code"]
            )
        }
        
        do {
            try self.argsString.write(to: URL(fileURLWithPath: "\(project.getCachePath().1)/args.txt"), atomically: false, encoding: .utf8)
        } catch {
            print(error.localizedDescription)
        }
        
        try Builder.isAbortedCheck()
    }
    
    func link() throws {
        // Path to the ld dylib
        let ldPath: String = "\(Bundle.main.bundlePath)/Frameworks/ld.dylib"
        
        // Preparing arguments for the linker
        let ldArgs: [String] = [
            "-syslibroot",
            Bootstrap.shared.bootstrapPath("/SDK/iPhoneOS16.5.sdk"),
            "-o",
            self.project.getMachOPath().1
        ] + FindFilesStack(
            project.getCachePath().1,
            ["o"],
            ["Resources","Config"]
        ) + self.project.projectConfig.linker_flags
        
        // Linkage execution
        if dyexec(
            ldPath,
            ldArgs
        ) != 0 {
            throw NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "[!] linking object files together to a executable failed"]
            )
        }
        
        try Builder.isAbortedCheck()
    }
    
    func sign() throws {
        // Now we copy use it
        if !CertBlob.isReady {
            throw NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "[!] zsign server doesnt run, please re/import your apple issued developer certificate"]
            )
        }
        
        let zsign = CertBlob.signer!
        
        if !zsign.sign(self.project.getBundlePath().1) {
            throw NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "[!] zsign server failed to sign app bundle"]
            )
        }
        
        try Builder.isAbortedCheck()
    }
    
    func package() throws {
        if FileManager.default.fileExists(atPath: self.project.getPackagePath().1) {
            try FileManager.default.removeItem(atPath: self.project.getPackagePath().1)
        }
        
        try FileManager.default.zipItem(
            at: URL(fileURLWithPath: self.project.getPayloadPath().1),
            to: URL(fileURLWithPath: self.project.getPackagePath().1)
        )
        
        try Builder.isAbortedCheck()
    }
    
    func install() throws {
        let installer = try Installer(
            path: self.project.getPackagePath().1.URLGet(),
            metadata: AppData(id: self.project.projectConfig.bundleid,
                              version: 1, name: self.project.projectConfig.displayname),
            image: nil
        )
        
        var invokedInstallationPopup: Bool = false
        let waitonmebaby: DispatchSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            if UIApplication.shared.canOpenURL(installer.iTunesLink) {
                UIApplication.shared.open(installer.iTunesLink, options: [:], completionHandler: { success in
                    if success {
                        invokedInstallationPopup = true
                    }
                    waitonmebaby.signal()
                })
            }
        }
        waitonmebaby.wait()
        
        if invokedInstallationPopup {
            sleep(1)
            if OpenAppAfterReinstallTrampolineSwitch(
                installer,
                self.project) {
                exit(0)
            } else {
                throw NSError(
                    domain: "",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "[!] failed to open application"]
                )
            }
        } else {
            throw NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "[!] failed to invoke application installation"]
            )
        }
    }
    
    static private func isAbortedCheck() throws {
        if Builder.abort {
            throw NSError(
                domain: "",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "[*] user aborted compilation"]
            )
        }
    }
    
    ///
    /// Static function to build the project
    ///
    static func buildProject(withProject project: AppProject,
                             completion: @escaping (Bool) -> Void) {
        pthread_dispatch {
            Bootstrap.shared.waitTillDone()
            
            Builder.abortHandler = {}
            Builder.abort = false
            
            var result: Bool = true
            let builder: Builder = Builder(
                project: project
            )
            
            var resetNeeded: Bool = false
            func progressStage(systemName: String? = nil, logMessage: String, increment: Double? = nil, handler: () throws -> Void) throws {
                let doReset: Bool = (increment == nil)
                if doReset, resetNeeded {
                    XCodeButton.resetProgress()
                    resetNeeded = false
                }
                if let systemName = systemName { XCodeButton.switchImage(systemName: systemName) }
                ls_nsprint("[*] \(logMessage)\n")
                try handler()
                if !doReset, let increment = increment {
                    XCodeButton.incrementProgress(progress: increment)
                    resetNeeded = true
                }
            }
            
            func progressFlowBuilder(flow: [(String?,String,Double?,() throws -> Void)]) throws {
                for item in flow { try progressStage(systemName: item.0, logMessage: item.1, increment: item.2, handler: item.3) }
            }
            
            ls_nsprint("[*] LDE Builder v1.0\n")
            
            do {
                // doit
                try progressFlowBuilder(flow: [
                    (nil,"cleaning",nil,{ try builder.clean() }),
                    (nil,"preparing",nil,{ try builder.prepare() }),
                    (nil,"compiling",nil,{ try builder.compile() }),
                    ("link","linking",0.3,{ try builder.link() }),
                    ("checkmark.seal.text.page.fill","signing",0.3,{ try builder.sign() }),
                    ("archivebox.fill","packaging",0.4,{ try builder.package() }),
                    (nil,"cleaning",nil,{ try builder.clean() }),
                    ("arrow.down.app.fill","installing",nil,{try builder.install() })
                ])
            } catch {
                if !Builder.abort {
                    result = false
                } else {
                    try? builder.clean()
                }
                ls_nsprint(error.localizedDescription)
            }
            
            completion(result)
        }
    }
}
