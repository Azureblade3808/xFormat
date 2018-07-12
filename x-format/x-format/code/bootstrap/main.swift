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

do {
	let arguments = CommandLine.arguments
	
	guard arguments.count > 1 else {
		throw RandomError(message: "Missing file argument.")
	}
	
	let file = arguments[1]
	try Formatter(file: file).work()
}
catch let error as RandomError {
	print(error.message)
}
catch _ as UnknownError {
	print("An unknown error occured.")
}
