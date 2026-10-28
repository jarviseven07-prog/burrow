import Foundation
import Combine

final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: SettingsKey.appLanguage) }
    }

    init() {
        self.language = UserDefaults.standard.string(forKey: SettingsKey.appLanguage) ?? "system"
    }

    var effectiveLanguage: String {
        if language == "system" {
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? "zh" : "en"
        }
        return language
    }

    subscript(_ key: String) -> String {
        Self.strings[effectiveLanguage]?[key] ?? Self.strings["en"]?[key] ?? key
    }

    // MARK: - Translations

    static let strings: [String: [String: String]] = [
        "en": en,
        "zh": zh,
    ]

    private static let en: [String: String] = [
        // Settings pages
        "sound": "Sound",

        // Behavior

        // Appearance
        "session_status_needs_you": "NEEDS YOU",
        "session_status_working": "WORKING",
        "session_status_thinking": "THINKING",
        "session_status_done": "DONE",
        "session_status_idle": "IDLE",
        "session_status_stopped": "STOPPED",
        "session_status_error": "ERROR",
        "copy_code": "Copy code",
        "quit_confirm": "QUIT?",
        "quit_confirm_hint": "Click again to quit",

        // Window
        "settings_title": "Burrow Settings",
        "about_based_on": "Built on CodeIsland by wxtsky (MIT License)",
        "burrow_a11y_pets": "Agent pets in the notch",
        "burrow_header_count": "%d in the burrow",
        "burrow_header_empty": "Burrow is empty",
        "burrow_back_title": "Settings",
        "burrow_back_return": "Back",
        "burrow_back_sound": "Sound",
        "burrow_back_mute_help": "Click to mute or unmute",
        "burrow_back_login": "Open at login",
        "burrow_back_connected": "Connected",
        "burrow_back_connect": "Connect",
        "burrow_back_shortcut_togglePanel": "Den",
        "burrow_back_shortcut_approve": "Allow",
        "burrow_back_shortcut_deny": "Deny",
        "burrow_back_shortcut_press": "Press keys…",
        "burrow_back_shortcut_none": "Not set",
        "burrow_back_shortcut_help": "Click, then press the new shortcut (esc cancels)",
        "burrow_back_reconnect": "Retry",
        "burrow_back_disconnect": "Unplug",
        "burrow_back_manage_help": "Click to reconnect or unplug",
        "burrow_back_sound_start": "Start",
        "burrow_back_sound_done": "Done",
        "burrow_back_sound_error": "Error",
        "burrow_back_sound_approval": "Needs you",
        "burrow_header_chats": "%d chats",
        "burrow_header_waiting": "Needs you",
        "burrow_empty_body": "No agents running. Start Claude Code, Codex, OpenCode or Antigravity and its pet moves in.",
        "burrow_what_thinking": "Thinking…",
        "burrow_what_idle": "Waiting",
        "burrow_what_stopped": "You stopped it",
        "burrow_what_error": "The last turn failed",
        "burrow_what_question": "Has a question for you",
        "burrow_done_title": "%@ is done",
        "burrow_fail_title": "%@ got stuck",
        "burrow_done_ok": "OK",
        "burrow_done_jump": "Jump back",
        "burrow_time_now": "now",
        "burrow_time_min": "%dm",
        "burrow_time_hour": "%dh",
        "burrow_time_waited": "waited %@",
        "burrow_time_rested": "resting %@",
        "burrow_time_ago": "%@ ago",
        "danger_remove": "rm -rf deletes these right away — they don't go to the Trash.",
        "danger_sudo": "sudo runs this as an administrator.",
        "danger_forcePush": "--force overwrites the commits on the remote.",
        "danger_resetHard": "reset --hard throws away changes you haven't committed.",
        "danger_clean": "git clean -f deletes untracked files for good.",
        "danger_drop": "DROP deletes a whole table or database.",
        "danger_chmodOpen": "chmod -R 777 lets anyone change these files.",

        // Menu
        "settings_ellipsis": "Settings...",
        "quit": "Quit",

        // NotchPanel
        "dismiss_card_hint": "Hide this card. The agent keeps waiting; click the island to bring it back.",
        "skip_question_hint": "Skip the question. The agent carries on without your answer.",
        "always_hint_session": "Allow, and stop asking about this tool for the rest of the session.",
        "always_hint_saved": "Allow, and save a rule in ~/.codex/rules so Codex stops asking for this command — in every session.",
        "always_hint_saved_mcp": "Allow, and save an approval in ~/.codex/config.toml so Codex stops asking for this MCP tool — in every session.",
        "card_queue_position": "%d of %d",
        "card_allow_once": "Allow once",
        "card_deny": "Deny",
        "card_hide": "Hide",
        "card_skip": "Skip",
        "card_back": "Back",
        "card_confirm": "Confirm",
        "card_submit": "Submit",
        "card_always_session": "Always allow %@ this session",
        "card_always_saved": "Always allow — saved to %@",
        "card_jump_hint": "Click to focus this session's terminal",
        "approval_title_command": "%@ wants to run a command",
        "approval_title_change_file": "%1$@ wants to change %2$@",
        "approval_title_change": "%@ wants to change files",
        "approval_title_read_file": "%1$@ wants to read %2$@",
        "approval_title_read": "%@ wants to read files",
        "approval_title_search": "%@ wants to search the files",
        "approval_title_web": "%@ wants to access the web",
        "approval_title_mcp": "%1$@ wants to call %2$@",
        "approval_title_agent": "%@ wants to start a subagent",
        "approval_title_generic": "%@ wants to run",
        "type_answer": "Type your answer...",

        // Session grouping
        "other": "Other",
        "lines": "lines",
        "reply_complete_placeholder": "Reply complete",
    ]

    private static let zh: [String: String] = [
        // Settings pages
        "sound": "声音",

        // Behavior

        // Appearance
        "session_status_needs_you": "待处理",
        "session_status_working": "运行中",
        "session_status_thinking": "思考中",
        "session_status_done": "已完成",
        "session_status_idle": "空闲",
        "session_status_stopped": "已中断",
        "session_status_error": "出错",
        "copy_code": "复制代码",
        "quit_confirm": "退出？",
        "quit_confirm_hint": "再点一次即退出",

        // Window
        "settings_title": "Burrow 设置",
        "about_based_on": "基于 wxtsky 的 CodeIsland 改造（MIT 许可）",
        "burrow_a11y_pets": "刘海里的 agent 宠物",
        "burrow_header_count": "%d 只在洞里",
        "burrow_header_empty": "洞里没人",
        "burrow_back_title": "设置",
        "burrow_back_return": "翻回去",
        "burrow_back_sound": "提示音",
        "burrow_back_mute_help": "点一下静音，再点一下打开",
        "burrow_back_login": "开机时打开",
        "burrow_back_connected": "连着",
        "burrow_back_connect": "连上",
        "burrow_back_shortcut_togglePanel": "打开小窝",
        "burrow_back_shortcut_approve": "允许",
        "burrow_back_shortcut_deny": "拒绝",
        "burrow_back_shortcut_press": "按下新按键…",
        "burrow_back_shortcut_none": "未设定",
        "burrow_back_shortcut_help": "点一下，再按新的快捷键（esc 取消）",
        "burrow_back_reconnect": "重连",
        "burrow_back_disconnect": "断开",
        "burrow_back_manage_help": "点一下：重连或断开",
        "burrow_back_sound_start": "开始",
        "burrow_back_sound_done": "做完",
        "burrow_back_sound_error": "出错",
        "burrow_back_sound_approval": "要你批准",
        "burrow_header_chats": "%d 个对话",
        "burrow_header_waiting": "等你回应",
        "burrow_empty_body": "没有正在运行的 agent。开一个 Claude Code、Codex、OpenCode 或 Antigravity，它的宠物就会住进来。",
        "burrow_what_thinking": "在想…",
        "burrow_what_idle": "待命",
        "burrow_what_stopped": "被你打断了",
        "burrow_what_error": "上一轮出错了",
        "burrow_what_question": "有问题要问你",
        "burrow_done_title": "%@ 做完了",
        "burrow_fail_title": "%@ 卡住了",
        "burrow_done_ok": "好的",
        "burrow_done_jump": "跳回去看看",
        "burrow_time_now": "刚刚",
        "burrow_time_min": "%d 分钟",
        "burrow_time_hour": "%d 小时",
        "burrow_time_waited": "等了 %@",
        "burrow_time_rested": "歇了 %@",
        "burrow_time_ago": "%@前",
        "danger_remove": "rm -rf 会直接删掉，不经过废纸篓。",
        "danger_sudo": "sudo 会用管理员权限运行。",
        "danger_forcePush": "--force 会覆盖远端的提交。",
        "danger_resetHard": "reset --hard 会丢掉还没提交的改动。",
        "danger_clean": "git clean -f 会删掉没纳入 git 的文件，找不回来。",
        "danger_drop": "DROP 会删掉整张表或整个数据库。",
        "danger_chmodOpen": "chmod -R 777 会让谁都能改这些文件。",

        // Menu
        "settings_ellipsis": "设置...",
        "quit": "退出",

        // NotchPanel
        "dismiss_card_hint": "收起这张卡片。Agent 会继续等待，点一下灵动岛即可找回。",
        "skip_question_hint": "跳过这个问题。Agent 会在没有你回答的情况下继续。",
        "always_hint_session": "允许，并在本次会话剩余时间内不再询问此工具。",
        "always_hint_saved": "允许，并在 ~/.codex/rules 中保存规则，此后 Codex 在所有会话中都不再询问这条命令。",
        "always_hint_saved_mcp": "允许，并在 ~/.codex/config.toml 中保存授权，此后 Codex 在所有会话中都不再询问这个 MCP 工具。",
        "card_queue_position": "第 %d/%d 个",
        "card_allow_once": "允许一次",
        "card_deny": "拒绝",
        "card_hide": "收起",
        "card_skip": "跳过",
        "card_back": "返回",
        "card_confirm": "确认",
        "card_submit": "提交",
        "card_always_session": "本会话始终允许 %@",
        "card_always_saved": "始终允许——保存到 %@",
        "card_jump_hint": "点击切换到这个会话的终端",
        "approval_title_command": "%@ 请求运行命令",
        "approval_title_change_file": "%1$@ 请求修改 %2$@",
        "approval_title_change": "%@ 请求修改文件",
        "approval_title_read_file": "%1$@ 请求读取 %2$@",
        "approval_title_read": "%@ 请求读取文件",
        "approval_title_search": "%@ 请求搜索文件",
        "approval_title_web": "%@ 请求访问网络",
        "approval_title_mcp": "%1$@ 请求调用 %2$@",
        "approval_title_agent": "%@ 请求启动子代理",
        "approval_title_generic": "%@ 请求运行",
        "type_answer": "输入回答…",

        // Session grouping
        "other": "其他",
        "lines": "行",
        "reply_complete_placeholder": "回复完成",
    ]
}
