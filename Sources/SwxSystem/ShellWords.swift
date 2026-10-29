/// Splits a command line the way a POSIX shell does, as build logs print commands: words are
/// separated by unquoted blanks; single quotes keep everything literal, double quotes and
/// backslashes escape the next character.
public enum ShellWords {
    private enum Character {
        static let singleQuote: Swift.Character = "'"
        static let doubleQuote: Swift.Character = "\""
        static let backslash: Swift.Character = "\\"
    }

    private enum Quoting {
        case none
        case single
        case double
    }

    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quoting = Quoting.none
        var escaped = false

        for character in line {
            // An escaped character is taken as is.
            if escaped {
                word.append(character)
                escaped = false
                continue
            }

            switch quoting {
            case .single:
                if character == Character.singleQuote {
                    quoting = .none
                } else {
                    word.append(character)
                }
                continue
            case .double:
                if character == Character.doubleQuote {
                    quoting = .none
                } else if character == Character.backslash {
                    escaped = true
                } else {
                    word.append(character)
                }
                continue
            case .none:
                break
            }

            // Unquoted: blanks end the word, quotes and backslashes start escaping.
            switch character {
            case Character.singleQuote:
                quoting = .single
                inWord = true
            case Character.doubleQuote:
                quoting = .double
                inWord = true
            case Character.backslash:
                escaped = true
                inWord = true
            case _ where character.isWhitespace:
                guard inWord else { continue }
                words.append(word)
                word = ""
                inWord = false
            default:
                word.append(character)
                inWord = true
            }
        }
        if inWord {
            words.append(word)
        }
        return words
    }
}
