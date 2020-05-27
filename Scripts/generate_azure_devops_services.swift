#!/usr/bin/swift

import Foundation

struct AzureDevOpsService {
    let serviceName: String

    var friendlyName: String {
        let friendlyServiceName = serviceName.components(separatedBy: " ").map {
            $0.capitalized(firstLetterOnly: true)
        }.joined(separator: " ")

        return "Azure DevOps \(friendlyServiceName)"
    }

    var className: String {
        var sanitizedName = serviceName
        sanitizedName = sanitizedName.replacingOccurrences(of: " & ", with: "And")
        sanitizedName = sanitizedName.replacingOccurrences(of: "/", with: "")
        sanitizedName = sanitizedName.replacingOccurrences(of: ":", with: "")
        sanitizedName = sanitizedName.components(separatedBy: " ").map { $0.capitalized(firstLetterOnly: true) }.joined(separator: "")
        return "AzureDevOps\(sanitizedName)"
    }

    var output: String {
        return """
        class \(className): AzureDevOps, SubService {
            let name = "\(friendlyName)"
            let serviceName = "\(serviceName)"
        }
        """
    }
}

extension String {
    subscript(_ range: NSRange) -> String {
        // Why we still have to do this shit in 2019 I don't know
        let start = self.index(self.startIndex, offsetBy: range.lowerBound)
        let end = self.index(self.startIndex, offsetBy: range.upperBound)
        let subString = self[start..<end]
        return String(subString)
    }

    func capitalized(firstLetterOnly: Bool) -> String {
        return firstLetterOnly ? (prefix(1).capitalized + dropFirst()) : self
    }
}

struct AzureDevOpsDataProviders: Codable {
    struct ResponseData: Codable {
        struct MetadataProvider: Codable {
            let services: [[String: String]]

            var serviceNames: [String] {
                return services.compactMap { $0["id"] }
            }
        }

        enum CodingKeys: String, CodingKey {
            case metadataProvider = "ms.vss-status-web.public-status-metadata-data-provider"
        }

        let metadataProvider: MetadataProvider
    }

    let data: ResponseData
}

func envVariable(forKey key: String) -> String {
    guard let variable = ProcessInfo.processInfo.environment[key] else {
        print("error: Environment variable '\(key)' not set")
        exit(1)
    }

    return variable
}

func discoverServices() -> [AzureDevOpsService] {
    var result = [AzureDevOpsService]()

    var dataResult: Data?

    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: URL(string: "https://status.dev.azure.com")!) { data, _, _ in
        dataResult = data
        semaphore.signal()
    }.resume()

    _ = semaphore.wait(timeout: .now() + .seconds(10))

    guard let data = dataResult, var body = String(data: data, encoding: .utf8) else {
        print("warning: Build script generate_azure_devops_services could not retrieve list of Azure DevOps services")
        exit(0)
    }

    body = body.replacingOccurrences(of: "\n", with: "")

    // swiftlint:disable:next force_try
    let regex = try! NSRegularExpression(
        pattern: "<script id=\"dataProviders\".*?>(.*?)</script>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    let range = NSRange(location: 0, length: body.count)
    regex.enumerateMatches(in: body, options: [], range: range) { textCheckingResult, _, _ in
        guard let textCheckingResult = textCheckingResult, textCheckingResult.numberOfRanges == 2 else { return }

        let json = body[textCheckingResult.range(at: 1)]
        guard let decodedProviders = try? JSONDecoder().decode(AzureDevOpsDataProviders.self, from: json.data(using: .utf8)!) else {
            print("warning: Build script generate_azure_devops_services could not retrieve list of Azure DevOps services")
            exit(0)
        }

        decodedProviders.data.metadataProvider.serviceNames.forEach {
            result.append(AzureDevOpsService(serviceName: $0))
        }
    }

    return result
}

func main() {
    let srcRoot = envVariable(forKey: "SRCROOT")
    let outputPath = "\(srcRoot)/stts/Services/Generated/AzureDevOpsServices.swift"
    let services = discoverServices()

    let header = """
    // This file is generated by generate_azure_devops_services.swift and should not be modified manually.

    import Foundation

    """

    let content = services.map { $0.output }.joined(separator: "\n\n")
    let footer = ""

    let output = [header, content, footer].joined(separator: "\n")

    // swiftlint:disable:next force_try
    try! output.write(toFile: outputPath, atomically: true, encoding: .utf8)
}

main()
