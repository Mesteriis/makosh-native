import MakoshCore
import MakoshTelemost

enum TelemostSyntheticLaunchPolicy {
    static func admits(arguments: [String], configuration: ContactWorkspaceConfiguration) -> Bool {
        (try? TelemostQAIsolation.validate(configuration: configuration, arguments: arguments)) != nil
    }
    static func permitsNormalLaunch(marker: String?, arguments: [String]) -> Bool {
        marker != "telemost" && !arguments.contains("--telemost-synthetic-preview")
    }
}
