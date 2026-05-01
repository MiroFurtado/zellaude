mod event_handler;
mod installer;
mod render;
mod state;
mod tab_pane_map;

use state::{unix_now, unix_now_ms, HookPayload, MenuAction, SessionInfo, Settings, State, ViewMode};
use std::collections::BTreeMap;
use zellij_tile::prelude::*;

const DONE_TIMEOUT: u64 = 30;
const TIMER_INTERVAL: f64 = 1.0;
const FLASH_TICK: f64 = 0.25;

register_plugin!(State);

impl ZellijPlugin for State {
    fn load(&mut self, _configuration: BTreeMap<String, String>) {
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
            PermissionType::RunCommands,
            PermissionType::ReadCliPipes,
            PermissionType::MessageAndLaunchOtherPlugins,
        ]);
        subscribe(&[
            EventType::TabUpdate,
            EventType::PaneUpdate,
            EventType::ModeUpdate,
            EventType::Timer,
            EventType::Mouse,
            EventType::RunCommandResult,
            EventType::PermissionRequestResult,
        ]);
        set_timeout(TIMER_INTERVAL);

        // Cache our own plugin pane id for later self-addressing (e.g. resize)
        self.plugin_pane_id = Some(get_plugin_ids().plugin_id);

        // Load persisted settings (may be retried in PermissionRequestResult
        // if this fires before permissions are granted)
        self.load_config();
    }

    fn update(&mut self, event: Event) -> bool {
        match event {
            Event::TabUpdate(tabs) => {
                let new_active = tabs.iter().find(|t| t.active).map(|t| t.position);
                if new_active != self.active_tab_index {
                    // Tab focus changed — clear persist flashes on the newly focused tab
                    if let Some(idx) = new_active {
                        self.clear_flashes_on_tab(idx);
                    }
                }
                self.active_tab_index = new_active;
                self.tabs = tabs;
                self.rebuild_pane_map();
                true
            }
            Event::PaneUpdate(manifest) => {
                self.pane_manifest = Some(manifest);
                self.rebuild_pane_map();
                true
            }
            Event::ModeUpdate(mode_info) => {
                self.input_mode = mode_info.mode;
                if let Some(name) = mode_info.session_name {
                    self.zellij_session_name = Some(name);
                    self.maybe_load_state();
                }
                true
            }
            Event::Mouse(Mouse::LeftClick(line, col)) => {
                // Mouse line is 0-based; render rows are 1-based.
                let row = (line as usize).saturating_add(1);
                let col = col as usize;

                // Prefix and settings menu live on row 1 only.
                if row == 1 {
                    if let Some((start, end)) = self.prefix_click_region {
                        if col >= start && col < end {
                            self.view_mode = match self.view_mode {
                                ViewMode::Normal => ViewMode::Settings,
                                ViewMode::Settings => ViewMode::Normal,
                            };
                            return true;
                        }
                    }
                }

                match self.view_mode {
                    ViewMode::Normal => {
                        for region in &self.click_regions {
                            if region.row == row
                                && col >= region.start_col
                                && col < region.end_col
                            {
                                if region.is_waiting {
                                    focus_terminal_pane(region.pane_id, false);
                                } else {
                                    switch_tab_to(region.tab_index as u32 + 1);
                                }
                                return false;
                            }
                        }
                        false
                    }
                    ViewMode::Settings => {
                        if row != 1 {
                            return false;
                        }
                        for region in &self.menu_click_regions {
                            if col >= region.start_col && col < region.end_col {
                                match &region.action {
                                    MenuAction::ToggleSetting(key) => {
                                        match key {
                                            state::SettingKey::Notifications => {
                                                self.settings.notifications =
                                                    self.settings.notifications.cycle();
                                            }
                                            state::SettingKey::Flash => {
                                                self.settings.flash =
                                                    self.settings.flash.cycle();
                                            }
                                            state::SettingKey::ElapsedTime => {
                                                self.settings.elapsed_time =
                                                    !self.settings.elapsed_time;
                                            }
                                            state::SettingKey::ModeIndicator => {
                                                self.settings.mode_indicator =
                                                    !self.settings.mode_indicator;
                                            }
                                        }
                                        self.save_config();
                                    }
                                    MenuAction::CloseMenu => {
                                        self.view_mode = ViewMode::Normal;
                                    }
                                }
                                return true;
                            }
                        }
                        false
                    }
                }
            }
            Event::RunCommandResult(exit_code, stdout, _stderr, context) => {
                match context.get("type").map(|s| s.as_str()) {
                    Some("load_config") if exit_code == Some(0) => {
                        let raw = String::from_utf8_lossy(&stdout);
                        if let Ok(settings) = serde_json::from_str::<Settings>(raw.trim()) {
                            self.settings = settings;
                        }
                        self.config_loaded = true;
                        true
                    }
                    Some("load_state") => {
                        if exit_code == Some(0) {
                            let raw = String::from_utf8_lossy(&stdout);
                            if let Ok(persisted) =
                                serde_json::from_str::<BTreeMap<u32, SessionInfo>>(raw.trim())
                            {
                                self.merge_sessions(persisted);
                            }
                        }
                        self.state_loaded = true;
                        true
                    }
                    Some("install_hooks") => {
                        self.hooks_installed = true;
                        false
                    }
                    _ => false,
                }
            }
            Event::Timer(_) => {
                let stale_changed = self.cleanup_stale_sessions();
                let flash_changed = self.cleanup_expired_flashes();
                let has_flashes = self.has_active_flashes();
                if has_flashes {
                    set_timeout(FLASH_TICK);
                } else {
                    set_timeout(TIMER_INTERVAL);
                }
                if stale_changed {
                    self.state_dirty = true;
                }
                if self.state_dirty && self.state_loaded {
                    self.save_state();
                    self.save_layout();
                    self.state_dirty = false;
                }
                has_flashes || stale_changed || flash_changed || self.has_elapsed_display()
            }
            Event::PermissionRequestResult(_) => {
                // Now that permissions are granted, mark as non-selectable
                // so the plugin stays visible during fullscreen
                set_selectable(false);
                // Permissions granted — ask existing instances for their state
                self.request_sync();
                // Retry config load (the one in load() may have been dropped
                // because it ran before permissions were granted)
                if !self.config_loaded {
                    self.load_config();
                }
                // Auto-install hook script and register Claude Code hooks
                if !self.hooks_installed {
                    installer::run_install();
                }
                false
            }
            _ => false,
        }
    }

    fn pipe(&mut self, pipe_message: PipeMessage) -> bool {
        match pipe_message.name.as_str() {
            "zellaude" => {
                // Hook event from CLI
                let payload_str = match pipe_message.payload {
                    Some(ref s) => s,
                    None => return false,
                };
                let payload: HookPayload = match serde_json::from_str(payload_str) {
                    Ok(p) => p,
                    Err(_) => return false,
                };
                event_handler::handle_hook_event(self, payload);
                true
            }
            "zellaude:focus" => {
                // Notification click — focus the requested pane
                if let Some(ref payload) = pipe_message.payload {
                    if let Ok(pane_id) = payload.trim().parse::<u32>() {
                        focus_terminal_pane(pane_id, false);
                    }
                }
                false
            }
            "zellaude:request" => {
                // Another instance asking for state — respond with ours
                self.broadcast_sessions();
                false
            }
            "zellaude:settings" => {
                // Another instance broadcast new settings
                if let Some(ref payload) = pipe_message.payload {
                    if let Ok(settings) = serde_json::from_str::<Settings>(payload) {
                        self.settings = settings;
                        return true;
                    }
                }
                false
            }
            "zellaude:sync" => {
                // Another instance sharing state — merge it
                if let Some(ref payload) = pipe_message.payload {
                    if let Ok(sessions) =
                        serde_json::from_str::<BTreeMap<u32, SessionInfo>>(payload)
                    {
                        self.merge_sessions(sessions);
                        return true;
                    }
                }
                false
            }
            "zellaude:resize" => {
                // Self-resize the plugin pane. Lets users grow the bar in
                // existing zellij sessions without re-creating them, since
                // set_selectable(false) blocks the usual focus+resize approach.
                // Payload "decrease" shrinks; anything else (or empty) grows.
                if let Some(pid) = self.plugin_pane_id {
                    let resize = match pipe_message.payload.as_deref().map(str::trim) {
                        Some("decrease") => Resize::Decrease,
                        _ => Resize::Increase,
                    };
                    let strategy = ResizeStrategy {
                        resize,
                        direction: Some(Direction::Down),
                        invert_on_boundaries: true,
                    };
                    resize_pane_with_id(strategy, PaneId::Plugin(pid));
                }
                false
            }
            _ => false,
        }
    }

    fn render(&mut self, rows: usize, cols: usize) {
        render::render_status_bar(self, rows, cols);
    }
}

impl State {
    fn rebuild_pane_map(&mut self) {
        if let Some(ref manifest) = self.pane_manifest {
            self.pane_to_tab = tab_pane_map::build_pane_to_tab_map(&self.tabs, manifest);
            self.refresh_session_tab_names();
            self.remove_dead_panes();
        }
    }

    fn refresh_session_tab_names(&mut self) {
        for session in self.sessions.values_mut() {
            if let Some((idx, name)) = self.pane_to_tab.get(&session.pane_id) {
                session.tab_index = Some(*idx);
                session.tab_name = Some(name.clone());
            }
        }
    }

    fn remove_dead_panes(&mut self) {
        let before = self.sessions.len();
        self.sessions
            .retain(|pane_id, _| self.pane_to_tab.contains_key(pane_id));
        if self.sessions.len() != before {
            self.state_dirty = true;
        }
    }

    fn cleanup_stale_sessions(&mut self) -> bool {
        let now = unix_now();
        let mut changed = false;
        for session in self.sessions.values_mut() {
            match session.activity {
                state::Activity::Done | state::Activity::AgentDone => {
                    if now.saturating_sub(session.last_event_ts) >= DONE_TIMEOUT {
                        session.activity = state::Activity::Idle;
                        changed = true;
                    }
                }
                _ => {}
            }
        }
        changed
    }

    fn clear_flashes_on_tab(&mut self, tab_idx: usize) {
        let pane_ids: Vec<u32> = self
            .sessions
            .values()
            .filter(|s| s.tab_index == Some(tab_idx))
            .map(|s| s.pane_id)
            .collect();
        for pane_id in pane_ids {
            self.flash_deadlines.remove(&pane_id);
        }
    }

    fn has_active_flashes(&self) -> bool {
        let now = unix_now_ms();
        self.flash_deadlines.values().any(|&deadline| now < deadline)
    }

    fn cleanup_expired_flashes(&mut self) -> bool {
        let before = self.flash_deadlines.len();
        let now = unix_now_ms();
        self.flash_deadlines.retain(|_, deadline| now < *deadline);
        self.flash_deadlines.len() != before
    }

    fn has_elapsed_display(&self) -> bool {
        if !self.settings.elapsed_time {
            return false;
        }
        let now = unix_now();
        self.sessions.values().any(|s| {
            !matches!(s.activity, state::Activity::Idle)
                && now.saturating_sub(s.last_event_ts) >= DONE_TIMEOUT
        })
    }

    fn request_sync(&self) {
        pipe_message_to_plugin(MessageToPlugin::new("zellaude:request"));
    }

    fn broadcast_sessions(&self) {
        let mut msg = MessageToPlugin::new("zellaude:sync");
        msg.message_payload =
            Some(serde_json::to_string(&self.sessions).unwrap_or_default());
        pipe_message_to_plugin(msg);
    }

    fn broadcast_settings(&self) {
        let mut msg = MessageToPlugin::new("zellaude:settings");
        msg.message_payload =
            Some(serde_json::to_string(&self.settings).unwrap_or_default());
        pipe_message_to_plugin(msg);
    }

    fn load_config(&self) {
        let mut ctx = BTreeMap::new();
        ctx.insert("type".into(), "load_config".into());
        run_command(
            &[
                "sh",
                "-c",
                "cat \"$HOME/.config/zellij/plugins/zellaude.json\" 2>/dev/null || echo '{}'",
            ],
            ctx,
        );
    }

    fn save_config(&self) {
        if !self.config_loaded {
            return;
        }
        self.broadcast_settings();
        let json = serde_json::to_string(&self.settings).unwrap_or_default();
        let json_esc = json.replace('\'', "'\\''");
        let cmd = format!(
            "mkdir -p \"$HOME/.config/zellij/plugins\" && printf '%s' '{json_esc}' > \"$HOME/.config/zellij/plugins/zellaude.json\""
        );
        let mut ctx = BTreeMap::new();
        ctx.insert("type".into(), "save_config".into());
        run_command(&["sh", "-c", &cmd], ctx);
    }

    fn merge_sessions(&mut self, incoming: BTreeMap<u32, SessionInfo>) {
        for (pane_id, mut session) in incoming {
            let dominated = self
                .sessions
                .get(&pane_id)
                .map(|existing| session.last_event_ts > existing.last_event_ts)
                .unwrap_or(true);
            if dominated {
                // Refresh tab name from our local pane map
                if let Some((idx, name)) = self.pane_to_tab.get(&pane_id) {
                    session.tab_index = Some(*idx);
                    session.tab_name = Some(name.clone());
                }
                self.sessions.insert(pane_id, session);
                self.state_dirty = true;
            }
        }
    }

    fn maybe_load_state(&mut self) {
        if self.state_load_started {
            return;
        }
        let Some(safe) = self
            .zellij_session_name
            .as_deref()
            .map(sanitize_session_name)
        else {
            return;
        };
        if safe.is_empty() {
            return;
        }
        self.state_load_started = true;
        let mut ctx = BTreeMap::new();
        ctx.insert("type".into(), "load_state".into());
        let cmd = format!(
            "cat \"$HOME/.config/zellij/plugins/zellaude-state/{safe}.json\" 2>/dev/null || echo '{{}}'"
        );
        run_command(&["sh", "-c", &cmd], ctx);
    }

    fn save_state(&self) {
        let Some(safe) = self
            .zellij_session_name
            .as_deref()
            .map(sanitize_session_name)
        else {
            return;
        };
        if safe.is_empty() {
            return;
        }
        let json = serde_json::to_string(&self.sessions).unwrap_or_default();
        let json_esc = json.replace('\'', "'\\''");
        let cmd = format!(
            "DIR=\"$HOME/.config/zellij/plugins/zellaude-state\" && mkdir -p \"$DIR\" && \
             TMP=$(mktemp \"$DIR/.tmp.XXXXXX\") && printf '%s' '{json_esc}' > \"$TMP\" && \
             mv \"$TMP\" \"$DIR/{safe}.json\""
        );
        let mut ctx = BTreeMap::new();
        ctx.insert("type".into(), "save_state".into());
        run_command(&["sh", "-c", &cmd], ctx);
    }

    /// Write a zellij layout snapshot for the current set of tabs, so the
    /// session can be recreated with the same tabs/cwds and each agent pane
    /// resumed to its prior session_id.
    fn save_layout(&self) {
        let Some(safe) = self
            .zellij_session_name
            .as_deref()
            .map(sanitize_session_name)
        else {
            return;
        };
        if safe.is_empty() || self.tabs.is_empty() {
            return;
        }
        let kdl = self.build_layout_kdl();
        let kdl_esc = kdl.replace('\'', "'\\''");
        let cmd = format!(
            "DIR=\"$HOME/.config/zellij/plugins/zellaude-state\" && mkdir -p \"$DIR\" && \
             TMP=$(mktemp \"$DIR/.tmp.XXXXXX\") && printf '%s' '{kdl_esc}' > \"$TMP\" && \
             mv \"$TMP\" \"$DIR/{safe}.kdl\""
        );
        let mut ctx = BTreeMap::new();
        ctx.insert("type".into(), "save_layout".into());
        run_command(&["sh", "-c", &cmd], ctx);
    }

    fn build_layout_kdl(&self) -> String {
        use std::fmt::Write;

        let mut tabs_sorted: Vec<&TabInfo> = self.tabs.iter().collect();
        tabs_sorted.sort_by_key(|t| t.position);

        let mut out = String::from("// Auto-generated by zellaude — recreate session via:\n");
        let _ = writeln!(
            out,
            "//   zellij --layout <this-file> --session {}",
            self.zellij_session_name.as_deref().unwrap_or("")
        );
        out.push_str("layout {\n");
        out.push_str("    default_tab_template {\n");
        out.push_str(
            "        pane size=2 borderless=true {\n            \
             plugin location=\"file:~/.config/zellij/plugins/zellaude.wasm\"\n        }\n",
        );
        out.push_str("        children\n    }\n\n");

        for tab in tabs_sorted {
            // Pick the highest-priority session for this tab — same heuristic
            // we use in the renderer to choose what to display.
            let session = self
                .sessions
                .values()
                .filter(|s| s.tab_index == Some(tab.position))
                .max_by_key(|s| s.last_event_ts);

            let _ = writeln!(out, "    tab name=\"{}\" {{", kdl_escape(&tab.name));

            match session {
                Some(s) if !s.session_id.is_empty() => {
                    let bin = match s.agent.as_deref() {
                        Some("cursor") => "cursor-agent",
                        _ => "claude",
                    };
                    let _ = write!(out, "        pane command=\"{bin}\"");
                    if let Some(cwd) = s.cwd.as_deref().filter(|c| !c.is_empty()) {
                        let _ = write!(out, " cwd=\"{}\"", kdl_escape(cwd));
                    }
                    out.push_str(" {\n");
                    let _ = writeln!(
                        out,
                        "            args \"--resume\" \"{}\"",
                        kdl_escape(&s.session_id)
                    );
                    out.push_str("        }\n");
                }
                Some(s) if s.cwd.as_deref().map(|c| !c.is_empty()).unwrap_or(false) => {
                    let _ = writeln!(
                        out,
                        "        pane cwd=\"{}\"",
                        kdl_escape(s.cwd.as_deref().unwrap_or(""))
                    );
                }
                _ => {
                    out.push_str("        pane\n");
                }
            }

            out.push_str("    }\n");
        }

        out.push_str("}\n");
        out
    }
}

fn kdl_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Strip characters that aren't safe in a filename. Zellij session names are
/// already restricted to a small charset, but this is a defense-in-depth guard
/// against shell-quoting surprises.
fn sanitize_session_name(name: &str) -> String {
    name.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .collect()
}
