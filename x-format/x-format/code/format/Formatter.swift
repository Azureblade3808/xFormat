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
		let startingDate = Date()
		defer {
			let stoppingDate = Date()
			let elapsedTime = stoppingDate.timeIntervalSince(startingDate)
			
			print("Elapsed time: \(elapsedTime).")
		}
		
		let fileData = try loadData(from: projectFileUrl)
		let jsonPlist: [String : Any] = try readAsJsonPlist(data: fileData)
		
		let objectIds: Set<String>
		let pathUrlMap: [String : URL]
		let convertedIdMap: [String : String]
		(objectIds, pathUrlMap, convertedIdMap) = try buildConversions(jsonPlist: jsonPlist)
		
		guard let fileContent = String(data: fileData, encoding: .utf8) else {
			throw UnknownError()
		}
		let fileLines = fileContent.components(separatedBy: .newlines)
		
		let (
			formattedFileLines,
			fileLinesAreModified
		) = try formatFileLines(
			fileLines,
			objectIds: objectIds,
			pathUrlMap: pathUrlMap,
			convertedIdMap: convertedIdMap
		)
		if fileLinesAreModified {
			let formattedFileContent = formattedFileLines.joined(separator: "\n")
			try formattedFileContent.write(to: projectFileUrl, atomically: true, encoding: .utf8)
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

fileprivate func readAsJsonPlist(data: Data) throws -> [String : Any] {
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

fileprivate func buildConversions(jsonPlist: [String : Any]) throws -> (
	objectIds: Set<String>,
	pathUrlMap: [String : URL],
	convertedIdMap: [String : String]
) {
	class Worker {
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
		
		private var objectIds: Set<String> = []
		
		private var pathUrlMap: [String : URL] = [:]
		
		private var convertedIdMap: [String : String] = [:]
		
		fileprivate func work() throws -> (
			objectIds: Set<String>,
			pathUrlMap: [String : URL],
			convertedIdMap: [String : String]
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
						let pathUrl = pathUrlMap[id]?.replacingScheme(with: nil)
					else {
						throw UnknownError()
					}
					
					try record(isa: isa, pathUrl: pathUrl, originalId: objectId)
				}
			}
			
			// All objects should be iterated and recorded.
			#if DEBUG
			if Set(jsonObjectMap.keys) != objectIds {
				throw UnknownError()
			}
			#endif
			
			// No two different IDs should share a same converted ID.
			#if DEBUG
			var reversedIdMap: [String : String] = [:]
			for (key, value) in convertedIdMap {
				if reversedIdMap.keys.contains(value) {
					throw UnknownError()
				}
				
				reversedIdMap[value] = key
			}
			#endif
			
			return (objectIds, pathUrlMap, convertedIdMap)
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
					throw UnknownError()
				}
			}
		}
		
		private func walkThrough(jsonProject: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
			let pathUrl = basePathUrl
			
			try record(isa: isa, pathUrl: pathUrl, originalId: originalId)
			
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
			
			try record(isa: isa, pathUrl: pathUrl, originalId: originalId)
			
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
			
			try record(isa: isa, pathUrl: pathUrl, originalId: originalId)
		}
		
		private func walkThrough(jsonConfigurationList: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
			let pathUrl = basePathUrl
			
			try record(isa: isa, pathUrl: pathUrl, originalId: originalId)
			
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
			
			try record(isa: isa, pathUrl: pathUrl, originalId: originalId)
		}
		
		private func walkThrough(jsonTarget: [String : Any], isa: String, originalId: String, basePathUrl: URL) throws {
			let pathUrl: URL
			if let name = jsonTarget["name"] as? String {
				pathUrl = basePathUrl.appendingPathComponent(name)
			}
			else {
				throw UnknownError()
			}
			
			try record(isa: isa, pathUrl: pathUrl, originalId: originalId)
			
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
			
			try record(isa: isa, pathUrl: pathUrl, originalId: originalId)
			
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
			
			try record(isa: isa, pathUrl: pathUrl, originalId: originalId)
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
			
			try record(isa: isa, pathUrl: pathUrl, originalId: originalId)
		}
		
		private func record(isa: String, pathUrl: URL, originalId: String) throws {
			// An ID should not be touched more than once.
			#if DEBUG
			if objectIds.contains(originalId) {
				throw UnknownError()
			}
			#endif
			
			objectIds.insert(originalId)
			
			pathUrlMap[originalId] = pathUrl.replacingScheme(with: isa)
			
			let convertedId = "\(isa)://\(pathUrl.path)".md5
			if convertedId != originalId {
				convertedIdMap[originalId] = convertedId
			}
		}
	}
	
	return try Worker(jsonPlist: jsonPlist).work()
}

// MARK: -

fileprivate func formatFileLines(
	_ lines: [String],
	objectIds: Set<String>,
	pathUrlMap: [String : URL],
	convertedIdMap: [String : String]
) throws -> ([String], Bool) {
	class Worker {
		private let lines: [String]
		
		private let objectIds: Set<String>
		
		private let pathUrlMap: [String : URL]
		
		private let convertedIdMap: [String : String]
		
		fileprivate init(
			_ lines: [String],
			objectIds: Set<String>,
			pathUrlMap: [String : URL],
			convertedIdMap: [String : String]
		) throws {
			self.lines = lines
			self.objectIds = objectIds
			self.pathUrlMap = pathUrlMap
			self.convertedIdMap = convertedIdMap
		}
		
		fileprivate func work() throws -> ([String], Bool) {
			return try formatFileLines(lines)
		}
		
		private let regexForSectionOpening = try! NSRegularExpression(pattern: "^\\/\\* Begin (\\w+) section \\*\\/$")
		
		private let regexForSectionClosing = try! NSRegularExpression(pattern: "^\\/\\* End (\\w+) section \\*\\/$")
		
		private func formatFileLines(_ lines: [String]) throws -> ([String], Bool) {
			var formattedLines: [String] = []
			var linesAreModified: Bool = false
			
			var pendingSection: (name: String, innerLines: [String])!
			
			for line in lines {
				if pendingSection == nil {
					if let result = regexForSectionOpening.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
						// Opening a section.
						
						formattedLines.append(line)
						
						let rangeOfName = result.range(at: 1)
						let name = (line as NSString).substring(with: rangeOfName)
						
						pendingSection = (name: name, innerLines: [])
					}
					else {
						// This is a irrelevant line.
						
						let (formattedLine, lineIsModified) = try formatLine(line)
						formattedLines.append(formattedLine)
						if lineIsModified {
							linesAreModified = true
						}
					}
				}
				else {
					if let result = regexForSectionClosing.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
						// Closing a section.
						
						#if DEBUG
						let rangeOfName = result.range(at: 1)
						let name = (line as NSString).substring(with: rangeOfName)
						
						guard name == pendingSection.name else {
							throw UnknownError()
						}
						#endif
						
						let (formattedSectionLines, sectionLinesAreModified) = try formatSectionLines(pendingSection.innerLines)
						formattedLines += formattedSectionLines
						if sectionLinesAreModified {
							linesAreModified = true
						}
						
						pendingSection = nil
						
						formattedLines.append(line)
					}
					else {
						// This is a section line.
						
						pendingSection.innerLines.append(line)
					}
				}
			}
			
			assert(formattedLines.count == lines.count)
			assert(linesAreModified == (formattedLines != lines))
			
			return (formattedLines, linesAreModified)
		}
		
		private func formatSectionLines(_ sectionLines: [String]) throws -> ([String], Bool) {
			// Treat section lines as map lines.
			return try formatMapLines(sectionLines)
		}
		
		/// Regular expression for matching opening of a map item.
		private let regexForMapItemOpening = try! NSRegularExpression(pattern: "^(\\t*)(?:(\\w+)|\"([^\"]+)\")(?: \\/\\*.*\\*\\/)? = ")
		
		private func formatMapLines(_ lines: [String]) throws -> ([String], Bool) {
			var formattedLines: [String] = []
			var linesAreModified: Bool = false
			
			var pendingFormattedItemLines: [String] = []
			var pendingFormattedItemKeys: [String] = []
			var pendingFormattedItemLinesRangeMap: [String : Range<Int>] = [:]
			
			var pendingItem: (key: String, isMap: Bool, openingLine: String, innerIndents: String, innerLines: [String])!
			
			for line in lines {
				if pendingItem == nil {
					if let result = regexForMapItemOpening.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
						var rangeForKey = result.range(at: 2)
						if rangeForKey.location == NSNotFound {
							rangeForKey = result.range(at: 3)
						}
						let key = (line as NSString).substring(with: rangeForKey)
						
						if line.hasSuffix(";") {
							// This is a single-line item.
							
							let (formattedLine, lineIsModified) = try formatLine(line)
							
							if lineIsModified {
								linesAreModified = true
							}
							
							if objectIds.contains(key) {
								// The key is an object ID.
								
								let fromIndex = pendingFormattedItemLines.count
								let toIndex = fromIndex + 1
								
								pendingFormattedItemLines.append(formattedLine)
								pendingFormattedItemKeys.append(key)
								pendingFormattedItemLinesRangeMap[key] = fromIndex ..< toIndex
							}
							else {
								// The key is irrelevant.
								
								guard pendingFormattedItemLines.isEmpty else {
									throw UnknownError()
								}
								
								formattedLines.append(formattedLine)
							}
						}
						else {
							// This is a multi-line item.
							
							let rangeForIndents = result.range(at: 1)
							let indents = (line as NSString).substring(with: rangeForIndents)
							
							let isMap = line.hasSuffix("{")
							
							pendingItem = (key: key, isMap: isMap, openingLine: line, innerIndents: indents + "\t", innerLines: [])
						}
					}
					else {
						// This is an irrelevant line.
						
						guard pendingFormattedItemLines.isEmpty else {
							throw UnknownError()
						}
						
						let (formattedLine, lineIsModified) = try formatLine(line)
						formattedLines.append(formattedLine)
						if lineIsModified {
							linesAreModified = true
						}
					}
				}
				else {
					if line.hasPrefix(pendingItem.innerIndents) {
						// This is another line of the pending item.
						
						pendingItem.innerLines.append(line)
					}
					else {
						// Closing the pending item.
						
						var formattedItemLines: [String] = []
						
						let (formattedOpeningLine, openingLineIsModified) = try formatLine(pendingItem.openingLine)
						formattedItemLines.append(formattedOpeningLine)
						if openingLineIsModified {
							linesAreModified = true
						}
						
						let (formattedInnerLines, innerLinesAreModified) = try (
							pendingItem.isMap ?
							formatMapLines(pendingItem.innerLines) :
							formatArrayLines(pendingItem.innerLines)
						)
						formattedItemLines += formattedInnerLines
						if innerLinesAreModified {
							linesAreModified = true
						}
						
						formattedItemLines.append(line)
						
						let key = pendingItem.key
						if objectIds.contains(key) {
							let fromIndex = pendingFormattedItemLines.count
							let toIndex = fromIndex + formattedItemLines.count
							
							pendingFormattedItemLines += formattedItemLines
							pendingFormattedItemKeys.append(key)
							pendingFormattedItemLinesRangeMap[key] = fromIndex ..< toIndex
						}
						else {
							formattedLines += formattedItemLines
						}
						
						pendingItem = nil
					}
				}
			}
			
			let keys = pendingFormattedItemKeys
			let sortedKeys = keys.sorted {
				// Sort by converted IDs.
				
				let convertedId0 = convertedIdMap[$0] ?? $0
				let convertedId1 = convertedIdMap[$1] ?? $1
				
				return convertedId0 <= convertedId1
			}
			
			if sortedKeys.elementsEqual(keys) {
				formattedLines += pendingFormattedItemLines
			}
			else {
				linesAreModified = true
				
				for key in sortedKeys {
					let formattedItemLinesRange = pendingFormattedItemLinesRangeMap[key]!
					let formattedItemlines = pendingFormattedItemLines[formattedItemLinesRange]
					formattedLines += formattedItemlines
				}
			}
			
			assert(formattedLines.count == lines.count)
			assert(linesAreModified == (formattedLines != lines))
			
			return (formattedLines, linesAreModified)
		}
		
		/// Regular expression for matching an array item.
		private let regexForArrayItem = try! NSRegularExpression(pattern: "^\\t*(?:(\\w+)|\"([^\"]+)\")(?: \\/\\*.*\\*\\/)?,$")
		
		private func formatArrayLines(_ lines: [String]) throws -> ([String], Bool) {
			var formattedLines: [String] = []
			var linesAreModified: Bool = false
			
			var pendingFormattedItemLines: [String] = []
			var pendingFormattedItemKeys: [String] = []
			var pendingFormattedItemLinesIndexMap: [String : Int] = [:]
			
			for line in lines {
				if let result = regexForArrayItem.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
					var rangeForKey = result.range(at: 1)
					if rangeForKey.location == NSNotFound {
						rangeForKey = result.range(at: 2)
					}
					let key = (line as NSString).substring(with: rangeForKey)
					
					let (formattedLine, lineIsModified) = try formatLine(line)
					
					if lineIsModified {
						linesAreModified = true
					}
					
					if objectIds.contains(key) {
						// The key is an object ID.
						
						let index = pendingFormattedItemLines.count
						
						pendingFormattedItemLines.append(formattedLine)
						pendingFormattedItemKeys.append(key)
						pendingFormattedItemLinesIndexMap[key] = index
					}
					else {
						// The key is irrelevant.
						
						guard pendingFormattedItemLines.isEmpty else {
							throw UnknownError()
						}
						
						formattedLines.append(formattedLine)
					}
				}
				else {
					// There should not be an irrelevant line.
					throw UnknownError()
				}
			}
			
			let keys = pendingFormattedItemKeys
			let sortedKeys = keys.sorted {
				// Sort by paths then converted IDs.
				
				let path0 = pathUrlMap[$0]!.path
				let path1 = pathUrlMap[$1]!.path
				if path0 < path1 {
					return true
				}
				else if path0 > path1 {
					return false
				}
				
				let convertedId0 = convertedIdMap[$0] ?? $0
				let convertedId1 = convertedIdMap[$1] ?? $1
				
				return convertedId0 < convertedId1
			}
			
			if sortedKeys.elementsEqual(keys) {
				formattedLines += pendingFormattedItemLines
			}
			else {
				linesAreModified = true
				
				for key in sortedKeys {
					let index = pendingFormattedItemLinesIndexMap[key]!
					let formattedLine = pendingFormattedItemLines[index]
					formattedLines.append(formattedLine)
				}
			}
			
			assert(formattedLines.count == lines.count)
			assert(linesAreModified == (formattedLines != lines))
			
			return (formattedLines, linesAreModified)
		}
		
		private let regexsForExtractingIds = [
			try! NSRegularExpression(pattern: "(\\w+|\\\"[^\\\"]+\\\") \\/\\*"),
			try! NSRegularExpression(pattern: "^\\t*(\\w+|\\\"[^\\\"]+\\\") = \\{"),
			try! NSRegularExpression(pattern: "^\\t*(?:mainGroup|remoteGlobalIDString|TestTargetID) = (\\w+|\\\"[^\\\"]+\\\");$"),
		]
		
		private func formatLine(_ line: String) throws -> (String, Bool) {
			var formattedLine: String = line
			var lineIsModified: Bool = false
			
			for regex in regexsForExtractingIds {
				for result in regex.matches(in: formattedLine, range: NSRange(location: 0, length: (formattedLine as NSString).length)).reversed() {
					let range = result.range(at: 1)
					let captureGroup = (formattedLine as NSString).substring(with: range)
					
					let id: String
					if captureGroup.hasPrefix("\"") {
						assert(captureGroup.hasSuffix("\""))
						
						id = String(captureGroup.dropFirst().dropLast())
					}
					else {
						id = captureGroup
					}
					
					if let convertedId = convertedIdMap[id] {
						formattedLine = (formattedLine as NSString).replacingCharacters(in: range, with: convertedId)
						lineIsModified = true
					}
				}
			}
			
			return (formattedLine, lineIsModified)
		}
	}
	
	return try Worker(lines, objectIds: objectIds, pathUrlMap: pathUrlMap, convertedIdMap: convertedIdMap).work()
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
