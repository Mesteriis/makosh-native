import Foundation

/// Minimal Jira Cloud REST v3 shapes, enough for the adapter's decoding.
enum JiraFixtures {
    static let me = #"{"accountId":"me-1","displayName":"Я","emailAddress":"me@example.com"}"#

    static let search = """
        {"issues":[
          {"id":"10001","key":"QA-1","fields":{"summary":"Первая","description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Строка один"},{"type":"hardBreak"},{"type":"text","text":"строка два"}]},{"type":"paragraph","content":[{"type":"text","text":"Абзац два"}]}]},
            "status":{"id":"1","name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"name":"Task"},"priority":{"id":"2","name":"High"},
            "assignee":{"accountId":"me-1","displayName":"Я"},"reporter":{"accountId":"pm-1","displayName":"PM"},"labels":["billing"],
            "duedate":"2026-11-20","updated":"2026-11-07T10:00:00.000+0300","project":{"key":"QA"}}},
          {"id":"10002","key":"QA-2","fields":{"summary":"Вторая","description":null,
            "status":{"id":"3","name":"Done","statusCategory":{"key":"done"}},"issuetype":{"name":"Bug"},"priority":null,
            "assignee":null,"reporter":null,"labels":[],"duedate":null,"updated":"2026-11-06T09:30:15.250Z","project":{"key":"QA"}}}
        ],"nextPageToken":"tok-2","isLast":false}
        """

    static let issue = """
        {"id":"10001","key":"QA-1","fields":{"summary":"Первая","description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Привет "},{"type":"mention","attrs":{"id":"me-1","text":"@Я"}}]}]},
          "status":{"id":"2","name":"In Progress","statusCategory":{"key":"indeterminate"}},"issuetype":{"name":"Task"},"priority":{"id":"3","name":"Medium"},
          "assignee":{"accountId":"me-1","displayName":"Я"},"reporter":{"accountId":"pm-1","displayName":"PM"},"labels":[],
          "duedate":null,"updated":"2026-11-07T12:00:00.000+0000","project":{"key":"QA"}}}
        """

    static let transitions = """
        {"transitions":[
          {"id":"11","name":"Start","to":{"id":"2","name":"In Progress","statusCategory":{"key":"indeterminate"}},"fields":{}},
          {"id":"31","name":"Done","to":{"id":"3","name":"Done","statusCategory":{"key":"done"}},
           "fields":{"resolution":{"required":true,"name":"Resolution","schema":{"type":"resolution"},"allowedValues":[{"id":"10000","name":"Done"},{"id":"10001","name":"Won't Do"}]},
                     "customfield_1":{"required":false,"name":"Note","schema":{"type":"string"}}}}
        ]}
        """

    static let comments = """
        {"startAt":0,"maxResults":50,"total":2,"comments":[
          {"id":"c1","author":{"accountId":"pm-1","displayName":"PM"},"created":"2026-11-07T08:00:00.000+0000","updated":"2026-11-07T08:00:00.000+0000",
           "body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Посмотри, пожалуйста"}]}]}},
          {"id":"c2","author":{"accountId":"me-1","displayName":"Я"},"created":"2026-11-07T09:00:00.000+0000","updated":"2026-11-07T09:05:00.000+0000",
           "body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Смотрю"}]}]}}
        ]}
        """

    static let worklogs = """
        {"startAt":0,"maxResults":1048576,"total":1,"worklogs":[
          {"id":"w1","author":{"accountId":"me-1","displayName":"Я"},"started":"2026-11-07T09:00:00.000+0300","timeSpentSeconds":1800,
           "comment":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"созвон"}]}]}}
        ]}
        """

    static let projectStatuses = """
        [{"id":"10001","name":"Task","statuses":[{"id":"1","name":"To Do","statusCategory":{"key":"new"}},{"id":"2","name":"In Progress","statusCategory":{"key":"indeterminate"}},{"id":"3","name":"Done","statusCategory":{"key":"done"}}]},
         {"id":"10002","name":"Bug","statuses":[{"id":"1","name":"To Do","statusCategory":{"key":"new"}},{"id":"3","name":"Done","statusCategory":{"key":"done"}}]}]
        """

    static let priorities = #"[{"id":"1","name":"Highest"},{"id":"2","name":"High"},{"id":"3","name":"Medium"}]"#

    static let assignable = #"[{"accountId":"bob-1","displayName":"Боб"},{"accountId":"me-1","displayName":"Я"}]"#
}
