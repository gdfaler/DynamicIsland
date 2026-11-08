import Foundation

/// Looks a user-facing string up in Localizable.strings (English text is the key; English needs no file).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
