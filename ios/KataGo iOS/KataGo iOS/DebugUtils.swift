//
//  DebugUtils.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/25.
//

import Foundation

/// A class that handles output to standard error.
class StandardError: TextOutputStream {
    /// Outputs the specified string to the standard error stream.
    func write(_ string: String) {
        /// Tries to write the UTF-8 encoded contents of the string to the standard error file handle.
        try? FileHandle.standardError.write(contentsOf: Data(string.utf8))
    }
}

/// A function to print error messages
func printError(_ item: Any) {
    // Create an instance of StandardError to direct output to the standard error stream
    var instance = StandardError()
    // Output the provided item to the standard error using the created instance
    print(item, to: &instance)
}
