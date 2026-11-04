import MakoshCore

package enum TelemostSyntheticLaunchPolicy {
    package static func admits(arguments: [String], configuration: ContactWorkspaceConfiguration) -> Bool {
        (try? TelemostQAIsolation.validate(configuration: configuration, arguments: arguments)) != nil
    }
    package static func permitsNormalLaunch(marker: String?, arguments: [String]) -> Bool {
        marker != "telemost" && !arguments.contains("--telemost-synthetic-preview")
    }
}
