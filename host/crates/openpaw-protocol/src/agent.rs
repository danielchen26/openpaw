use crate::wire_enum::wire_enum;

wire_enum! {
    /// Coding agent that produced an event.
    pub enum AgentKind {
        /// Anthropic Claude Code.
        ClaudeCode = "claude-code",
        /// OpenAI Codex CLI.
        Codex = "codex",
        /// OpenCode.
        OpenCode = "opencode",
        /// Google Gemini CLI.
        GeminiCli = "gemini-cli",
        /// Cursor CLI.
        CursorCli = "cursor-cli",
        /// Moonshot Kimi CLI.
        KimiCli = "kimi-cli",
        /// Alibaba Qwen Code.
        QwenCode = "qwen-code",
        /// Any other terminal agent discovered generically.
        Generic = "generic",
    }
}

impl AgentKind {
    /// Two character tag embedded in [`crate::SessionId`].
    ///
    /// Short tags keep session ids readable on a phone screen and inside tmux
    /// target names, and they stay inside the schema's session id pattern.
    pub const fn short(&self) -> &'static str {
        match self {
            AgentKind::ClaudeCode => "cc",
            AgentKind::Codex => "cx",
            AgentKind::OpenCode => "oc",
            AgentKind::GeminiCli => "gm",
            AgentKind::CursorCli => "cu",
            AgentKind::KimiCli => "km",
            AgentKind::QwenCode => "qw",
            AgentKind::Generic => "gn",
        }
    }

    /// Inverse of [`AgentKind::short`].
    pub fn from_short(short: &str) -> Option<AgentKind> {
        AgentKind::ALL
            .iter()
            .copied()
            .find(|agent| agent.short() == short)
    }
}
