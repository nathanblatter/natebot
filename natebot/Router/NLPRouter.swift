import Foundation

// MARK: - NLP Result

struct NLPResult {
    let action: String
    let params: [String: Any]
}

// MARK: - NLP Router
// Passes natural-language messages to Claude and parses structured JSON actions.

class NLPRouter {
    let claude: ClaudeAPI

    static let systemPrompt = """
    You are NateBot's action router. Given a user's natural language message, determine the \
    appropriate action and return a compact JSON object.

    Available actions:
    - cal_add        → Add a calendar event.
                       params: { title, date (natural language, e.g. "Friday at 2pm"),
                                 duration_minutes (default 60), location?, notes? }
    - cal_parse      → Bulk-parse text to extract many events.
                       params: { text }
    - remind_add     → Add a reminder.
                       params: { title, due_date? (natural language), list? ("default"|"work"|"school") }
    - remind_parse   → Bulk-parse text to extract many reminders.
                       params: { text }
    - status_all     → Check all registered apps. params: {}
    - status_single  → Check one app.           params: { app_name }
    - sys_health     → System CPU/RAM/Disk.     params: {}
    - docker_status  → Docker container list.   params: {}
    - docker_stop    → Stop a Docker container. params: { container_name }
    - briefing       → Morning briefing.        params: {}
    - log            → Recent activity log.     params: {}
    - help           → Help message.            params: {}
    - goal_checkin   → User is reporting they completed a personal goal (e.g. "I prayed this morning", "finished my run").
                       params: { goal_name (string matching one of their goals, e.g. "morning prayer", "run"),
                                 note? (any extra context, e.g. "for 20 mins") }
    - goal_add       → User wants to add a new personal goal.
                       params: { name (string, title-cased, 2-5 words), frequency ("daily"|"weekly"),
                                 reminder_time? ("HH:MM" 24h format, include only if user mentions a time) }
    - finforge_briefing  → user wants a financial summary, asks about money/finances/net worth.   params: {}
    - finforge_portfolio → user asks about stocks, holdings, portfolio, investments.              params: {}
    - finforge_predict   → user asks about risk or prediction for a specific ticker.
                           params: { symbol (e.g. "AAPL") }
    - finforge_goals     → user asks about financial goals, savings progress.                    params: {}
    - finforge_watchlist → user asks about watchlist, stock prices they're tracking.              params: {}
    - finforge_chat      → user asks any other finance question that needs detailed analysis.
                           params: { message (the original question) }
    - unknown        → Cannot determine.        params: { reason }

    Rules:
    - Return ONLY valid JSON. No markdown, no explanation.
    - Format: {"action":"action_name","params":{...}}
    - For cal_parse / remind_parse, set params.text to the full original message.
    - For status_single, match app_name to common names (e.g. "survivor", "therapist", "codenames").
    """

    init(claude: ClaudeAPI) {
        self.claude = claude
    }

    // MARK: - Route

    func route(_ message: String, completion: @escaping (NLPResult) -> Void) {
        claude.call(system: Self.systemPrompt, userMessage: message) { result in
            switch result {
            case .success(let text):
                if let parsed = Self.parseJSON(text) {
                    completion(parsed)
                } else {
                    completion(NLPResult(action: "unknown", params: ["reason": "Could not parse router response"]))
                }
            case .failure(let err):
                print("[NLPRouter] Claude error: \(err)")
                completion(NLPResult(action: "error", params: ["reason": err.localizedDescription]))
            }
        }
    }

    // MARK: - JSON parser

    static func parseJSON(_ text: String) -> NLPResult? {
        guard let jsonStr = text.extractJSONObject(),
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else { return nil }

        let params = json["params"] as? [String: Any] ?? [:]
        return NLPResult(action: action, params: params)
    }
}
