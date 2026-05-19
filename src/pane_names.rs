pub const ELAPSED_THRESHOLD: u64 = 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaneActivity {
    Init,
    Thinking,
    Tool,
    Prompting,
    Waiting,
    Notification,
    Done,
    AgentDone,
    Idle,
}

pub fn activity_icon(activity: PaneActivity) -> &'static str {
    match activity {
        PaneActivity::Init => "◆",
        PaneActivity::Thinking => "●",
        PaneActivity::Tool => "⚡",
        PaneActivity::Prompting => "▶",
        PaneActivity::Waiting => "⚠",
        PaneActivity::Notification => "◇",
        PaneActivity::Done | PaneActivity::AgentDone => "✓",
        PaneActivity::Idle => "○",
    }
}

pub fn format_elapsed(elapsed: u64, enabled: bool) -> Option<String> {
    if !enabled || elapsed < ELAPSED_THRESHOLD {
        None
    } else if elapsed < 3600 {
        Some(format!("{}m", elapsed / 60))
    } else {
        Some(format!("{}h", elapsed / 3600))
    }
}

pub fn compose(activity: PaneActivity, base: &str, elapsed: Option<&str>) -> String {
    let icon = activity_icon(activity);
    let base = strip_elapsed_suffix(base);
    let base = strip_transient_prefix(&base);
    let base = base.trim();
    match (base.is_empty(), elapsed) {
        (true, Some(elapsed)) => format!("{icon} ({elapsed})"),
        (true, None) => icon.to_string(),
        (false, Some(elapsed)) => format!("{icon} {base} ({elapsed})"),
        (false, None) => format!("{icon} {base}"),
    }
}

pub fn reconcile_base_name(
    existing_base: Option<&str>,
    current_title: Option<&str>,
    last_applied: Option<&str>,
) -> Option<String> {
    let current_title = current_title?;
    if Some(current_title) == last_applied {
        return None;
    }

    let candidate = strip_status_prefix(current_title);
    let has_existing_base = existing_base
        .map(|name| !name.trim().is_empty())
        .unwrap_or(false);

    if starts_with_status_icon(current_title)
        && (!has_existing_base || !candidate.trim().is_empty())
    {
        Some(candidate)
    } else if !has_existing_base && !candidate.trim().is_empty() {
        Some(candidate)
    } else {
        None
    }
}

pub fn strip_status_prefix(name: &str) -> String {
    let trimmed = name.trim();
    let Some(icon) = trimmed.chars().next() else {
        return String::new();
    };
    if !is_status_icon(icon) {
        return strip_transient_prefix(&strip_elapsed_suffix(trimmed));
    }
    let rest = trimmed[icon.len_utf8()..].trim_start();
    let rest = strip_elapsed_suffix(rest);
    let rest = strip_transient_prefix(&rest);
    if rest.is_empty() || starts_with_agent_label(&rest) {
        String::new()
    } else {
        rest
    }
}

pub fn strip_elapsed_suffix(s: &str) -> String {
    let mut current = s.trim().to_string();
    loop {
        let trimmed = current.trim_end();
        let candidate = trimmed.strip_suffix(')').unwrap_or(trimmed);
        let Some(open_idx) = candidate.rfind('(') else {
            return trimmed.to_string();
        };
        let elapsed = candidate[(open_idx + 1)..].trim();
        if !is_elapsed_label(elapsed) {
            return trimmed.to_string();
        }
        current = candidate[..open_idx].trim_end().to_string();
    }
}

pub fn starts_with_status_icon(name: &str) -> bool {
    name.trim()
        .chars()
        .next()
        .map(is_status_icon)
        .unwrap_or(false)
}

fn is_status_icon(c: char) -> bool {
    matches!(c, '◆' | '●' | '⚡' | '▶' | '⚠' | '◇' | '✓' | '○')
}

fn starts_with_agent_label(s: &str) -> bool {
    ["Claude", "Codex", "Cursor"]
        .iter()
        .any(|agent| s == *agent || s.starts_with(&format!("{agent} ")))
}

fn strip_transient_prefix(s: &str) -> String {
    let trimmed = s.trim_start();
    let mut chars = trimmed.chars();
    let Some(first) = chars.next() else {
        return String::new();
    };
    let rest = chars.as_str();
    if is_braille_pattern(first) && rest.starts_with(char::is_whitespace) {
        rest.trim_start().to_string()
    } else {
        trimmed.to_string()
    }
}

fn is_braille_pattern(c: char) -> bool {
    ('\u{2800}'..='\u{28ff}').contains(&c)
}

fn is_elapsed_label(s: &str) -> bool {
    let Some(unit) = s.chars().last() else {
        return false;
    };
    if !matches!(unit, 'm' | 'h') {
        return false;
    }
    s[..s.len() - unit.len_utf8()]
        .chars()
        .all(|c| c.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_status_prefix_and_preserves_user_name() {
        assert_eq!(strip_status_prefix("⚠ api-server"), "api-server");
        assert_eq!(strip_status_prefix("● train job (7m)"), "train job");
        assert_eq!(strip_status_prefix("  ✓ docs  "), "docs");
    }

    #[test]
    fn strips_old_agent_only_generated_names() {
        assert_eq!(strip_status_prefix("⚠ Claude"), "");
        assert_eq!(strip_status_prefix("● Codex (6m)"), "");
        assert_eq!(strip_status_prefix("✓ Cursor Bash"), "");
    }

    #[test]
    fn leaves_non_zellaude_titles_as_base_names() {
        assert_eq!(strip_status_prefix("api-server"), "api-server");
        assert_eq!(strip_status_prefix("codex"), "codex");
        assert_eq!(strip_status_prefix("Pane #3"), "Pane #3");
    }

    #[test]
    fn strips_codex_spinner_prefix_from_titles() {
        assert_eq!(strip_status_prefix("⠙ dotfiles"), "dotfiles");
        assert_eq!(strip_status_prefix("◆ ⠸ dotfiles"), "dotfiles");
        assert_eq!(compose(PaneActivity::Thinking, "⠙ dotfiles", Some("6m")), "● dotfiles (6m)");
    }

    #[test]
    fn strips_complete_and_malformed_elapsed_suffixes() {
        assert_eq!(strip_elapsed_suffix("api-server (6m)"), "api-server");
        assert_eq!(strip_elapsed_suffix("api-server (6m"), "api-server");
        assert_eq!(strip_elapsed_suffix("api-server (6m (6m)"), "api-server");
        assert_eq!(strip_elapsed_suffix("api-server (6m) (7m)"), "api-server");
        assert_eq!(strip_elapsed_suffix("api-server (build)"), "api-server (build)");
    }

    #[test]
    fn composes_status_base_and_elapsed_once() {
        assert_eq!(compose(PaneActivity::Waiting, "api-server", Some("2h")), "⚠ api-server (2h)");
        assert_eq!(compose(PaneActivity::Thinking, "api-server (6m)", Some("7m")), "● api-server (7m)");
        assert_eq!(compose(PaneActivity::Thinking, "api-server (6m", Some("7m")), "● api-server (7m)");
        assert_eq!(compose(PaneActivity::Idle, "", Some("4m")), "○ (4m)");
    }

    #[test]
    fn elapsed_label_uses_minutes_and_hours() {
        assert_eq!(format_elapsed(59, true), None);
        assert_eq!(format_elapsed(60, true), Some("1m".to_string()));
        assert_eq!(format_elapsed(3599, true), Some("59m".to_string()));
        assert_eq!(format_elapsed(3600, true), Some("1h".to_string()));
        assert_eq!(format_elapsed(7200, false), None);
    }

    #[test]
    fn learns_initial_non_empty_title() {
        assert_eq!(
            reconcile_base_name(None, Some("api-server"), None),
            Some("api-server".to_string())
        );
    }

    #[test]
    fn ignores_own_applied_title() {
        assert_eq!(
            reconcile_base_name(Some("api-server"), Some("● api-server (7m)"), Some("● api-server (7m)")),
            None
        );
    }

    #[test]
    fn ignores_noisy_process_title_after_base_is_known() {
        assert_eq!(
            reconcile_base_name(Some("api-server"), Some("codex"), Some("● api-server (7m)")),
            None
        );
        assert_eq!(
            reconcile_base_name(Some("api-server"), Some(""), Some("● api-server (7m)")),
            None
        );
    }

    #[test]
    fn recovers_base_from_zellaude_prefixed_title() {
        assert_eq!(
            reconcile_base_name(Some("api-server"), Some("● api-server (7m)"), Some("● old-name (6m)")),
            Some("api-server".to_string())
        );
    }

    #[test]
    fn does_not_replace_existing_base_with_empty_agent_only_title() {
        assert_eq!(
            reconcile_base_name(Some("api-server"), Some("⚠ Claude"), Some("● api-server (7m)")),
            None
        );
    }

    #[test]
    fn repeated_elapsed_refreshes_do_not_accumulate_suffixes() {
        let mut base = "api-server".to_string();
        let mut last_applied = String::new();

        for elapsed in ["6m", "6m", "7m", "1h"] {
            base = strip_elapsed_suffix(&base);
            last_applied = compose(PaneActivity::Thinking, &base, Some(elapsed));
            assert_eq!(last_applied.matches('(').count(), 1);
            assert_eq!(last_applied.matches(')').count(), 1);
        }

        assert_eq!(last_applied, "● api-server (1h)");
    }

    #[test]
    fn polluted_cached_base_is_cleaned_before_composing() {
        assert_eq!(
            compose(PaneActivity::Thinking, "api-server (6m (6m", Some("7m")),
            "● api-server (7m)"
        );
        assert_eq!(
            compose(PaneActivity::Thinking, "api-server (6m (6m)", Some("7m")),
            "● api-server (7m)"
        );
    }

    #[test]
    fn process_title_churn_does_not_replace_known_base() {
        let base = Some("api-server");
        let last = Some("● api-server (6m)");

        for noisy_title in ["codex", "claude", "bash", "Pane #3", ""] {
            assert_eq!(reconcile_base_name(base, Some(noisy_title), last), None);
        }
    }

    #[test]
    fn malformed_visible_zellaude_title_can_still_recover_base() {
        assert_eq!(
            reconcile_base_name(
                Some("old-name"),
                Some("● api-server (6m (6m"),
                Some("● old-name (5m)")
            ),
            Some("api-server".to_string())
        );
    }
}
