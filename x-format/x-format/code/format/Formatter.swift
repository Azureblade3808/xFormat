//	Copyright (c) 2018 傅立业, (Chris Fu, 17433201@qq.com)
//
//	Licensed under the Apache License, Version 2.0 (the "License");
//	you may not use this file except in compliance with the License.
//	You may obtain a copy of the License at
//
//	   http://www.apache.org/licenses/LICENSE-2.0
//
//	Unless required by applicable law or agreed to in writing, software
//	distributed under the License is distributed on an "AS IS" BASIS,
//	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//	See the License for the specific language governing permissions and
//	limitations under the License.

import Foundation

internal class Formatter {
	private let projectFileUrl: URL
	
	internal init(file: String) throws {
		let fileUrl = URL(fileURLWithPath: file)
		
		switch fileUrl.pathExtension {
		case "pbxproj":
			projectFileUrl = fileUrl
		
		case "xcodeproj":
			projectFileUrl = fileUrl.appendingPathComponent("project.pbxproj")
		
		default:
			throw RandomError(message:
				"""
				File argument should have an extension of either "pbxproj" or "xcodeproj".
				"""
			)
		}
	}
	
	internal func work() throws {
		let originalFileData = try loadData(from: projectFileUrl)
		let jsonPlist: [String : Any] = try convertToJsonPlist(data: originalFileData)
		
		let pathUrlMap: [String : URL]
		let idMap: [String : String]
		(pathUrlMap, idMap) = try MapsBuilder(jsonPlist: jsonPlist).work()
		
		guard let originalFileContent = String(data: originalFileData, encoding: .utf8) else {
			throw UnknownError()
		}
		let originalLines = originalFileContent.components(separatedBy: .newlines)
		
		let formattedLines = try formatLines(
			originalLines,
			pathUrlMap: pathUrlMap,
			idMap: idMap
		)
		let formattedFileContent = formattedLines.joined(separator: "\n")
		
		if formattedFileContent != originalFileContent {
			try? formattedFileContent.write(to: projectFileUrl, atomically: true, encoding: .utf8)
		}
	}
}

// MARK: -

fileprivate func loadData(from fileUrl: URL) throws -> Data {
	guard let data = try? Data(contentsOf: fileUrl) else {
		throw RandomError(message:
			"""
			Cannot read file \(fileUrl.path).
			"""
		)
	}
	return data
}

// MARK: -

fileprivate func convertToJsonPlist(data: Data) throws -> [String : Any] {
	let inputPipe = Pipe()
	let outputPipe = Pipe()
	
	let process = Process()
	process.launchPath = "/usr/bin/env"
	process.arguments = "plutil -convert json -r -o - -".components(separatedBy: .whitespaces)
	process.standardInput = inputPipe
	process.standardOutput = outputPipe
	process.launch()
	
	inputPipe.fileHandleForWriting.write(data)
	inputPipe.fileHandleForWriting.closeFile()
	
	let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
	
	guard process.terminationReason == .exit else {
		throw RandomError(message:
			"""
			Cannot convert project file into JSON format.
			
			Please check:
			1. The project file is under a correct structure.
			2. Xcode command-line utilities have been installed.
			"""
		)
	}
	
	guard let jsonObject = try? JSONSerialization.jsonObject(with: outputData, options: []) else {
		throw UnknownError()
	}
	
	guard let jsonPlist = jsonObject as? [String : Any] else {
		throw UnknownError()
	}
	
	return jsonPlist
}

// MARK: -

fileprivate class MapsBuilder {
	private let jsonObjectMap: [String : [String : Any]]
	
	private let rootObjectId: String
	
	fileprivate init(jsonPlist: [String : Any]) throws {
		guard let jsonObjectMap = jsonPlist["objects"] as? [String : [String : Any]] else {
			throw UnknownError()
		}
		self.jsonObjectMap = jsonObjectMap
		
		guard let rootObjectId = jsonPlist["rootObject"] as? String else {
			throw UnknownError()
		}
		self.rootObjectId = rootObjectId
	}
	
	// Records node path URLs by their original IDs.
	private var pathUrlMap: [String : URL] = [:]
	
	// Records converted node IDs by their original IDs.
	private var idMap: [String : String] = [:]
	
	fileprivate func work() throws -> (
		pathUrlMap: [String : URL],
		idMap: [String : String]
	) {
		try walkThrough(objectId: rootObjectId, basePathUrl: URL(fileURLWithPath: "/"))
		
		// Determination of paths of "PBXTargetDependency" nodes are delayed
		// until now, as paths of "PBXContainerInfoProxy" nodes have been determined.
		for (objectId, jsonObject) in jsonObjectMap {
			guard let isa = jsonObject["isa"] as? String else {
				throw UnknownError()
			}
			
			if isa == "PBXTargetDependency" {
				guard
					let id = jsonObject["targetProxy"] as? String,
					let pathUrl = pathUrlMap[id]
				else {
					throw UnknownError()
				}
				
				record(isa: isa, pathUrl: pathUrl, originalId: objectId)
			}
		}
		
		#if DEBUG
		var reversedIdMap: [String : String] = [:]
		
		for (key, value) in idMap {
			if reversedIdMap[value] != nil {
				fatalError()
			}
			
			reversedIdMap[value] = key
		}
		#endif
		
		return (pathUrlMap, idMap)
	}
	
	private func walkThrough(objectId: String, basePathUrl: URL) throws {
		guard let jsonObject = jsonObjectMap[objectId] else {
			throw UnknownError()
		}
		
		guard let isa = jsonObject["isa"] as? String else {
			throw UnknownError()
		}
		
		switch isa {
		case "PBXProject":
			try walkThrough(jsonProject: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
		
		case "PBXGroup", "PBXVariantGroup":
			try walkThrough(jsonGroup: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
		
		case "PBXFileReference":
			try walkThrough(jsonFileReference: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
		
		case "XCConfigurationList":
			try walkThrough(jsonConfigurationList: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
		
		case "XCBuildConfiguration":
			try walkThrough(jsonBuildConfiguration: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
		
		case "PBXNativeTarget":
			try walkThrough(jsonTarget: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
		
		case "PBXTargetDependency":
			try walkThrough(jsonTargetDependency: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
		
		case "PBXContainerItemProxy":
			try walkThrough(jsonContainerItemProxy: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
		
		case "PBXBuildFile":
			try walkThrough(jsonBuildFile: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
		
		default:
			if isa.hasPrefix("PBX") && isa.hasSuffix("BuildPhase") {
				try walkThrough(jsonBuildPhase: jsonObject, isa: isa, originalId: objectId, basePathUrl: basePathUrl)
			}
			else {
				fatalError()
			}
		}
	}
	
	private func walkThrough(jsonProject: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl = basePathUrl
		record(isa: isa, pathUrl: pathUrl, originalId: originalId)
		
		if let id = jsonProject["mainGroup"] as? String {
			try walkThrough(objectId: id, basePathUrl: pathUrl)
		}
		else {
			throw UnknownError()
		}
		
		if let ids = jsonProject["targets"] as? [String] {
			for id in ids {
				try walkThrough(objectId: id, basePathUrl: pathUrl)
			}
		}
		else {
			throw UnknownError()
		}
		
		if let id = jsonProject["buildConfigurationList"] as? String {
			try walkThrough(objectId: id, basePathUrl: pathUrl)
		}
		else {
			throw UnknownError()
		}
	}
	
	private func walkThrough(jsonGroup: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl: URL
		if let name = jsonGroup["name"] as? String {
			pathUrl = basePathUrl.appendingPathComponent("|\(name)|")
		}
		else if let path = jsonGroup["path"] as? String {
			pathUrl = basePathUrl.appendingPathComponent(path)
		}
		else {
			pathUrl = basePathUrl
		}
		
		record(isa: isa, pathUrl: pathUrl, originalId: originalId)
		
		if let ids = jsonGroup["children"] as? [String] {
			for id in ids {
				try walkThrough(objectId: id, basePathUrl: pathUrl)
			}
		}
		else {
			throw UnknownError()
		}
	}
	
	private func walkThrough(jsonFileReference: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl: URL
		if let name = jsonFileReference["name"] as? String {
			pathUrl = basePathUrl.appendingPathComponent("|\(name)|")
		}
		else if let path = jsonFileReference["path"] as? String {
			pathUrl = basePathUrl.appendingPathComponent(path)
		}
		else {
			throw UnknownError()
		}
		
		record(isa: isa, pathUrl: pathUrl, originalId: originalId)
	}
	
	private func walkThrough(jsonConfigurationList: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl = basePathUrl
		
		record(isa: isa, pathUrl: pathUrl, originalId: originalId)
		
		if let ids = jsonConfigurationList["buildConfigurations"] as? [String] {
			for id in ids {
				try walkThrough(objectId: id, basePathUrl: pathUrl)
			}
		}
		else {
			throw UnknownError()
		}
	}
	
	private func walkThrough(jsonBuildConfiguration: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl: URL
		if let name = jsonBuildConfiguration["name"] as? String {
			pathUrl = basePathUrl.appendingPathComponent(name)
		}
		else {
			throw UnknownError()
		}
		
		record(isa: isa, pathUrl: pathUrl, originalId: originalId)
	}
	
	private func walkThrough(jsonTarget: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl: URL
		if let name = jsonTarget["name"] as? String {
			pathUrl = basePathUrl.appendingPathComponent(name)
		}
		else {
			throw UnknownError()
		}
		
		record(isa: isa, pathUrl: pathUrl, originalId: originalId)
		
		if let id = jsonTarget["buildConfigurationList"] as? String {
			try walkThrough(objectId: id, basePathUrl: pathUrl)
		}
		else {
			throw UnknownError()
		}
		
		if let ids = jsonTarget["buildPhases"] as? [String] {
			for id in ids {
				try walkThrough(objectId: id, basePathUrl: pathUrl)
			}
		}
		else {
			throw UnknownError()
		}
		
		if let ids = jsonTarget["dependencies"] as? [String] {
			for id in ids {
				try walkThrough(objectId: id, basePathUrl: pathUrl)
			}
		}
		else {
			throw UnknownError()
		}
		
		if let ids = jsonTarget["buildRules"] as? [String] {
			for id in ids {
				try walkThrough(objectId: id, basePathUrl: pathUrl)
			}
		}
		else {
			throw UnknownError()
		}
	}
	
	private func walkThrough(jsonBuildPhase: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl: URL
		if let name = jsonBuildPhase["name"] as? String {
			pathUrl = basePathUrl.appendingPathComponent("|\(name)|")
		}
		else if let path = jsonBuildPhase["path"] as? String {
			pathUrl = basePathUrl.appendingPathComponent(path)
		}
		else {
			pathUrl = basePathUrl
		}
		
		record(isa: isa, pathUrl: pathUrl, originalId: originalId)
		
		if let ids = jsonBuildPhase["files"] as? [String] {
			for id in ids {
				try walkThrough(objectId: id, basePathUrl: pathUrl)
			}
		}
		else {
			throw UnknownError()
		}
	}
	
	private func walkThrough(jsonBuildFile: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl: URL
		if let id = jsonBuildFile["fileRef"] as? String {
			pathUrl = basePathUrl.appendingPathComponent(pathUrlMap[id]!.lastPathComponent)
		}
		else {
			throw UnknownError()
		}
		
		record(isa: isa, pathUrl: pathUrl, originalId: originalId)
	}
	
	private func walkThrough(jsonTargetDependency: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl = basePathUrl
		
		// Actual path for this node is not determined yet, so it's not going
		// to be recorded now.
		
		if let id = jsonTargetDependency["targetProxy"] as? String {
			try walkThrough(objectId: id, basePathUrl: pathUrl)
		}
		else {
			throw UnknownError()
		}
	}
	
	private func walkThrough(jsonContainerItemProxy: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
		let pathUrl: URL
		if let name = jsonContainerItemProxy["remoteInfo"] as? String {
			pathUrl = basePathUrl.appendingPathComponent(name)
		}
		else {
			throw UnknownError()
		}
		
		record(isa: isa, pathUrl: pathUrl, originalId: originalId)
	}
	
	private func record(isa: String, pathUrl: URL, originalId: String) {
		#if DEBUG
		if pathUrlMap[originalId] != nil {
			fatalError()
		}
	
		if idMap[originalId] != nil {
			fatalError()
		}
		#endif
		
		pathUrlMap[originalId] = pathUrl.replacingScheme(with: isa)
		
		idMap[originalId] = "\(isa)://\(pathUrl.path)".md5
	}
}

// MARK: -

fileprivate func formatLines(_ lines: [String], pathUrlMap: [String : URL], idMap: [String : String]) throws -> [String] {
	var formattedLines: [String] = []
	
	var shouldTreatPendingGroupAsMap: Bool = false
	var pendingGroup: (innerIndents: String, innerLines: [String])!
	
	for line in lines {
		if pendingGroup == nil {
			let formattedLine = try formatLine(line, pathUrlMap: pathUrlMap, idMap: idMap)
			formattedLines.append(formattedLine)
			
			if line.hasSuffix("{") {
				// Opening a group of a map.
				
				let indents = String(line.prefix { $0 == "\t" })
				let innerIndents = indents + "\t"
				
				shouldTreatPendingGroupAsMap = true
				pendingGroup = (innerIndents: innerIndents, innerLines: [])
			}
			else if line.hasSuffix("(") {
				// Opening a group of an array.
				
				let indents = String(line.prefix { $0 == "\t" })
				let innerIndents = indents + "\t"
				
				shouldTreatPendingGroupAsMap = false
				pendingGroup = (innerIndents: innerIndents, innerLines: [])
			}
		}
		else {
			if line.hasPrefix(pendingGroup.innerIndents) {
				// This is an inner line of the pending group.
				
				pendingGroup.innerLines.append(line)
			}
			else {
				if shouldTreatPendingGroupAsMap {
					formattedLines += (
						try formatMapLines(pendingGroup.innerLines, pathUrlMap: pathUrlMap, idMap: idMap)
					)
					
					if line.trimmingCharacters(in: .whitespaces).hasPrefix("}") {
						// Closing the pending group.
						
						pendingGroup = nil
					}
					else {
						// Closing a section.
						
						pendingGroup.innerLines.removeAll()
					}
				}
				else {
					formattedLines += (
						try formatArrayLines(pendingGroup.innerLines, pathUrlMap: pathUrlMap, idMap: idMap)
					)
					
					if line.trimmingCharacters(in: .whitespaces).hasPrefix(")") {
						// Closing the pending group.
						
						pendingGroup = nil
					}
					else {
						// Closing a section.
						
						pendingGroup.innerLines.removeAll()
					}
				}
				
				formattedLines.append(
					try formatLine(line, pathUrlMap: pathUrlMap, idMap: idMap)
				)
			}
		}
	}
	
	guard pendingGroup == nil else {
		// If there is still a pending group, the project file must have been malformed.
		throw UnknownError()
	}
	
	return formattedLines
}

fileprivate let regexForMapItemOpening = try! NSRegularExpression(pattern: "^(\\t*)(?:(\\w+)|\"([^\"]+)\")(?: \\/\\*.*\\*\\/)? =")

fileprivate func formatMapLines(_ lines: [String], pathUrlMap: [String : URL], idMap: [String : String]) throws -> [String] {
	var formattedLines: [String] = []
	
	/// Formatted lines of items, which are not added to `formattedLines` yet,
	/// mapped against their original IDs.
	var pendingFormattedItemLinesMap: [String : [String]] = [:]
	
	func flushPendingFormattedItemLinesMap() throws {
		if pendingFormattedItemLinesMap.isEmpty {
			return
		}
		
		// Sort by converted IDs.
		let sortedKeys = pendingFormattedItemLinesMap.keys.sorted {
			return idMap[$0]! <= idMap[$1]!
		}
		
		for key in sortedKeys {
			let formattedItemLines = pendingFormattedItemLinesMap[key]!
			formattedLines += formattedItemLines
		}
		
		pendingFormattedItemLinesMap.removeAll()
	}
	
	/// Incomplete item.
	var pendingItem: (originalId: String, openingLine: String, innerIndents: String, innerLines: [String])!
	
	for line in lines {
		if pendingItem == nil {
			try {
				if let result = regexForMapItemOpening.firstMatch(in: line, range:NSRange(location: 0, length: (line as NSString).length)) {
					var rangeForKey = result.range(at: 2)
					if rangeForKey.location == NSNotFound {
						rangeForKey = result.range(at: 3)
					}
					let key = (line as NSString).substring(with: rangeForKey)
					
					if key == "A7327C61C0D13B2C9DC8D63ED52589E7" {
						_ = 0
					}
					
					if pathUrlMap[key] != nil {
						if line.hasSuffix("};") {
							// This is a single-line item.
							
							let formattedLine = try formatLine(line, pathUrlMap: pathUrlMap, idMap: idMap)
							pendingFormattedItemLinesMap[key] = [formattedLine]
						}
						else {
							// This is a multi-line item.
							
							let rangeForIndents = result.range(at: 1)
							let indents = (line as NSString).substring(with: rangeForIndents)
							let innerIndents = indents + "\t"
							
							pendingItem = (originalId: key, openingLine: line, innerIndents: innerIndents, innerLines: [])
						}
						
						return
					}
				}
				
				try flushPendingFormattedItemLinesMap()
				
				let formattedLine = try formatLine(line, pathUrlMap: pathUrlMap, idMap: idMap)
				formattedLines.append(formattedLine)
			} ()
		}
		else {
			if line.hasPrefix(pendingItem.innerIndents) {
				// Continuing the pending item.
				
				pendingItem.innerLines.append(line)
			}
			else {
				// Closing the pending item.
				
				var formattedItemLines: [String] = []
				formattedItemLines.append(
					try formatLine(pendingItem.openingLine, pathUrlMap: pathUrlMap, idMap: idMap)
				)
				formattedItemLines += (
					try formatLines(pendingItem.innerLines, pathUrlMap: pathUrlMap, idMap: idMap)
				)
				formattedItemLines.append(
					try formatLine(line, pathUrlMap: pathUrlMap, idMap: idMap)
				)
				
				pendingFormattedItemLinesMap[pendingItem.originalId] = formattedItemLines
				
				pendingItem = nil
			}
		}
	}
	
	guard pendingItem == nil else {
		// All items should be closed.
		throw UnknownError()
	}
	
	try flushPendingFormattedItemLinesMap()
	
	return formattedLines
}

fileprivate let regexForArrayItem = try! NSRegularExpression(pattern: "^\\t*(?:(\\w+)|\"([^\"]+)\")(?: \\/\\*.*\\*\\/)?,$")

fileprivate let sortedIsas = [
	"PBXGroup",
]

fileprivate func formatArrayLines(_ lines: [String], pathUrlMap: [String : URL], idMap: [String : String]) throws -> [String] {
	var formattedLines: [String] = []
	
	/// Formatted lines of items, which are not added to `formattedLines` yet,
	/// mapped against their original IDs.
	var pendingFormattedItemLineMap: [String : String] = [:]
	
	func flushPendingFormattedItemLineMap() throws {
		if pendingFormattedItemLineMap.isEmpty {
			return
		}
		
		// Sort by paths or IDs.
		let sortedKeys = pendingFormattedItemLineMap.keys.sorted {
			let url0 = pathUrlMap[$0]!
			let url1 = pathUrlMap[$1]!
			
			let isa0 = url0.scheme!
			let isa1 = url1.scheme!
			if let index0 = sortedIsas.index(of: isa0) {
				if let index1 = sortedIsas.index(of: isa1) {
					if index0 < index1 {
						return true
					}
					else if index0 > index1 {
						return false
					}
				}
				else {
					return true
				}
			}
			else {
				if sortedIsas.contains(isa1) {
					return false
				}
			}
			
			let path0 = url0.path
			let path1 = url1.path
			if path0 < path1 {
				return true
			}
			else if path0 > path1 {
				return false
			}
			
			let convertedId0 = idMap[$0]!
			let convertedId1 = idMap[$1]!
			
			return convertedId0 <= convertedId1
		}
		
		for key in sortedKeys {
			let formattedItemLine = pendingFormattedItemLineMap[key]!
			formattedLines.append(formattedItemLine)
		}
		
		pendingFormattedItemLineMap.removeAll()
	}
	
	for line in lines {
		try {
			if let result = regexForArrayItem.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
				var rangeForKey = result.range(at: 1)
				if rangeForKey.location == NSNotFound {
					rangeForKey = result.range(at: 2)
				}
				let key = (line as NSString).substring(with: rangeForKey)
				
				if pathUrlMap[key] != nil {
					let formattedItemLine = try formatLine(line, pathUrlMap: pathUrlMap, idMap: idMap)
					pendingFormattedItemLineMap[key] = formattedItemLine
					
					return
				}
			}
			
			try flushPendingFormattedItemLineMap()
			
			let formattedLine = try formatLine(line, pathUrlMap: pathUrlMap, idMap: idMap)
			formattedLines.append(formattedLine)
		} ()
	}
	
	try flushPendingFormattedItemLineMap()
	
	return formattedLines
}

let regexsForMatchingIds = [
	try! NSRegularExpression(pattern: "(\\w+|\\\"[^\\\"]+\\\") \\/\\*"),
	try! NSRegularExpression(pattern: "^\\t*(\\w+|\\\"[^\\\"]+\\\") = \\{"),
	try! NSRegularExpression(pattern: "^\\t*(?:mainGroup|remoteGlobalIDString|TestTargetID) = (\\w+|\\\"[^\\\"]+\\\");$"),
]

fileprivate func formatLine(_ line: String, pathUrlMap: [String : URL], idMap: [String : String]) throws -> String {
	var line = line
	
	for regex in regexsForMatchingIds {
		let results = regex.matches(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length))
		if results.isEmpty {
			continue
		}
		
		for result in results.reversed() {
			let range = result.range(at: 1)
			assert(range.location != NSNotFound)
			
			let captureGroup = (line as NSString).substring(with: range)
			
			let originalId: String
			if captureGroup.first! == "\"" && captureGroup.last! == "\"" {
				originalId = String(captureGroup.dropFirst().dropLast())
			}
			else {
				originalId = captureGroup
			}
			
			if let convertedId = idMap[originalId] {
				line = (line as NSString).replacingCharacters(in: range, with: "\(convertedId)")
			}
			else {
				continue
			}
		}
	}
	
	return line
}

// MARK: -

extension URL {
	fileprivate func replacingScheme(with scheme: String?) -> URL {
		var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
		if components.scheme == scheme {
			return self
		}
		
		components.scheme = scheme
		let url = components.url!
		
		return url
	}
}

// MARK: -

extension String {
	fileprivate var md5: String {
		var digest = Array(repeating: 0 as UInt8, count: Int(CC_MD5_DIGEST_LENGTH))
		
		let data = self.data(using: .utf8)!
		_ = data.withUnsafeBytes {
			CC_MD5($0, CC_LONG(data.count), &digest)
		}
		
		var digestHex = ""
		for index in 0 ..< Int(CC_MD5_DIGEST_LENGTH) {
			digestHex += String(format: "%02X", digest[index])
		}
		
		return digestHex
	}
}
