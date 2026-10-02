import CoreML

/// Reads the class labels a YOLO Core ML export stores in its creator-defined metadata, as either
/// a `"classes"` CSV or a `"names"` dictionary string like `{0: 'person', 1: 'bicycle', ...}`.
enum ModelLabels {
    static func parse(_ model: MLModel) -> [String] {
        guard
            let userDefined = model.modelDescription
                .metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String]
        else {
            return []
        }

        if let csv = userDefined["classes"] {
            return csv.components(separatedBy: ",")
        }

        guard let names = userDefined["names"] else { return [] }
        return
            names
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .components(separatedBy: ",")
            .compactMap { pair in
                let parts = pair.components(separatedBy: ":")
                guard parts.count == 2 else { return nil }
                return parts[1]
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "'", with: "")
            }
    }
}
