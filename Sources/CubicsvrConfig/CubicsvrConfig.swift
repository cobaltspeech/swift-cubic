//  CubicsvrConfig.swift
//
//  Created by Eduard Miniakhmetov on 29.11.2021.
//  Copyright © 2021 Cobalt Speech and Language Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
    

import Foundation
import TOMLKit
import UIKit

public struct PathConfiguration {
    
    public var resourceDirectory: String
    public var licenseDirectory: String
    public var modelsDirectory: String
    
    public init(resourceDirectory: String, licenseDirectory: String, modelsDirectory: String) {
        self.resourceDirectory = resourceDirectory
        self.modelsDirectory = modelsDirectory
        self.licenseDirectory = licenseDirectory
    }
    
}

public struct CubicsvrConfig: Codable {
    
    public var pathConfiguration: PathConfiguration = PathConfiguration(resourceDirectory: "Cubicsvr",
                                                                        licenseDirectory: "license",
                                                                        modelsDirectory: "models") {
        didSet {
            guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return
            }
            
            let resourcesURL = documentsPath.appendingPathComponent(pathConfiguration.resourceDirectory)
            let licenseURL = resourcesURL.appendingPathComponent(pathConfiguration.licenseDirectory)
            let modelsURL = resourcesURL.appendingPathComponent(pathConfiguration.modelsDirectory)
            
            for url in [resourcesURL, licenseURL, modelsURL] {
                if !directoryExists(path: url) {
                    createDirectory(url)
                }
            }
        }
    }
    
    public var Version: Int = 5
    public var server: Server = Server()
    public var logging: Logging?
    public var license: License = License()
    public var recognizer: Recognizer?
    public var storage: Storage?
    public var models: [Model] = []
    
    private enum CodingKeys : String, CodingKey {
        case Version, server, logging, license, recognizer, storage, models
    }
    
    public struct Server: Codable {
        public var grpc: GRPC
        public var http: HTTP?
        
        public init() {
            self.grpc = GRPC()
        }
    }
    
    public struct GRPC: Codable {
        public var Address: String?
        public var CertFile: String?
        public var KeyFile: String?
    }
    
    public struct HTTP: Codable {
        public struct API: Codable {
            public var Address: String
            public var CertFile: String?
            public var KeyFile: String?
            public var EnableWebDemo: Bool?
            public var WebRootPath: String?
        }
        
        public struct Ops: Codable {
            public var Address: String
            public var CertFile: String?
            public var KeyFile: String?
        }
        
        public var api: API?
        public var ops: Ops?
    }
    
    public struct Logging: Codable {
        public var DisableInfo: Bool?
        public var EnableDebug: Bool?
        public var EnableTrace: Bool?
    }

    public struct License: Codable {
        public var KeyFile: String = ""
        public var UsageLog: String?
    }

    public struct Recognizer: Codable {
        public var MaxTTL: Int64?
        public var MaxIdleTimeout: Int64?
        public var MaxAudioBytes: UInt64?
    }

    public struct Storage: Codable {
        public var type: String?
        public var BasePath: String?
        
        private enum CodingKeys : String, CodingKey {
            case type = "Type", BasePath
        }
    }

    public struct Model: Codable {
        public struct Confidence: Codable {
            public var ModelPath: String
            public var LMPath: String
        }
        
        public var ID: String
        public var Name: String
        public var ModelConfigPath: String
        public var FormatterConfigPath: String?
        public var confidence: Confidence?
    }
    
    public init(pathConfiguration: PathConfiguration) {
        self.pathConfiguration = pathConfiguration
    }

    public mutating func addModel(id: String, name: String, path: String) {
        let model = Model(ID: id,
                          Name: name,
                          ModelConfigPath: path)
        models.append(model)
    }
    
    public mutating func removeModel(id: String) {
        models.removeAll { $0.ID == id }
    }
    
    public func getTOMLString() -> String? {
        do {
            return try tomlString()
        } catch {
            print(error)
            return nil
        }
    }
    
    public init?(tomlString: String, pathConfiguration: PathConfiguration?) {
        do {
            var config = try TOMLDecoder().decode(Self.self, from: tomlString)
            if let pathConfiguration = pathConfiguration {
                config.pathConfiguration = pathConfiguration
            }
            print(config)
            self = config
        } catch {
            print(error)
            return nil
        }
    }
    
    @discardableResult
    public func save(_ path: URL) -> String? {
        guard let absolutePathsConfig = configWithAbsolutePaths() else {
            return nil
        }
        
        do {
            var tomlString = try absolutePathsConfig.tomlString()
            
            tomlString = tomlString.replacingOccurrences(of: "[server.grpc]", with: "[server]\n[server.http]\n[server.grpc]")
            tomlString.append(contentsOf: "\n\n[logging]\n\n[recognizer]\n\n[storage]")
            
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
            
            try tomlString.write(to: path, atomically: true, encoding: .utf8)
            var relativeTomlString = try self.tomlString()
            relativeTomlString = relativeTomlString.replacingOccurrences(of: "[server.grpc]", with: "[server]\n[server.http]\n[server.grpc]")
            relativeTomlString.append(contentsOf: "\n\n[logging]\n\n[recognizer]\n\n[storage]")
            return relativeTomlString
        } catch {
            print(error)
            return nil
        }
    }

}

private extension CubicsvrConfig {
    
    private func directoryExists(path: URL) -> Bool {
        var isDirectory = ObjCBool(true)
        let directoryExists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
        
        return directoryExists && isDirectory.boolValue
    }
    
    private func createDirectory(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            print(error)
        }
    }
    
    private func tomlString() throws -> String {
        return try TOMLEncoder().encode(self)
    }
    
    private func configWithAbsolutePaths() -> CubicsvrConfig? {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let resourcesURL = documentsPath.appendingPathComponent(pathConfiguration.resourceDirectory)
        let licenseURL = resourcesURL.appendingPathComponent(pathConfiguration.licenseDirectory)
        let modelsURL = resourcesURL.appendingPathComponent(pathConfiguration.modelsDirectory)
        
        var result = self
        
        result.license.KeyFile = licenseURL.appendingPathComponent(result.license.KeyFile).path
        
        for i in 0..<result.models.count {
            result.models[i].ModelConfigPath = modelsURL.appendingPathComponent(result.models[i].ModelConfigPath).path
            
            if let formatterConfigPath = result.models[i].FormatterConfigPath {
                result.models[i].FormatterConfigPath = modelsURL.appendingPathComponent(formatterConfigPath).path
            }
        }
        
        return result
    }
    
}
