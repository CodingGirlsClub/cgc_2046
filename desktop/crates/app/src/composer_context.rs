use std::{collections::HashMap, path::Path};

use cgc_agent_ui::conversation::{
    ContextAttachment, ContextAttachmentKind, DraftToken, MessageDraft,
};
use gpui_kit::component::input::{InlineToken, InputContent, TextareaState};
use gpui_kit::{App, Entity, Window};

use crate::{
    mention::Mention,
    page_context::{ConversationScope, FrozenPageContext, PageContext, PageContextState},
};

pub(crate) const AUTO_PAGE_TOKEN: &str = "context:auto-page";
const SNAPSHOT_PREFIX: &str = "context:snapshot:";

#[derive(Clone, Default)]
pub(crate) struct ComposerContext {
    pub snapshots: HashMap<String, ContextAttachment>,
    auto_initialized: bool,
}

impl ComposerContext {
    pub(crate) fn reset(&mut self) {
        *self = Self::default();
    }

    pub(crate) fn restore(&mut self, draft: &MessageDraft) -> InputContent {
        self.disable_auto();
        self.snapshots = draft
            .attachments
            .iter()
            .cloned()
            .map(|item| (item.id.clone(), item))
            .collect();
        let mut content = InputContent::new(draft.text.clone());
        for token in &draft.tokens {
            if let Ok(updated) = content.clone().with_token(
                token.range.clone(),
                InlineToken::new(token.id.clone(), token.text.clone())
                    .with_label(token.label.clone()),
            ) {
                content = updated;
            }
        }
        content
    }

    pub(crate) fn ensure_auto(
        &mut self,
        input: &Entity<TextareaState>,
        page: Option<&PageContext>,
        window: &mut Window,
        cx: &mut App,
    ) {
        if self.auto_initialized || page.is_none() {
            return;
        }
        let inserted = input.update(cx, |state, cx| {
            let selection = state.selected_range();
            let scroll = state.scroll_offset();
            let token = auto_page_token();
            let length = token.text().len();
            if state
                .replace_range_with_token(0..0, token, window, cx)
                .is_err()
            {
                return false;
            }
            state.set_selected_range(selection.start + length..selection.end + length, cx);
            state.set_scroll_offset(scroll, cx);
            true
        });
        self.auto_initialized = inserted;
    }

    pub(crate) fn add_page(&mut self, page: PageContext) -> InlineToken {
        self.add_snapshot(
            ContextAttachmentKind::Page,
            page.chip_title(),
            page.route.clone(),
            crate::page_context::context_note(&page, 20_000),
            serde_json::to_string(&page).ok(),
        )
    }

    pub(crate) fn add_selection(&mut self, page: PageContext, text: String) -> InlineToken {
        let label = format!("{} · Selection", page.chip_title());
        let content = format!(
            "{}\n\n[Selected page content]\n{}",
            crate::page_context::context_note(&page, 0),
            text
        );
        self.add_snapshot(
            ContextAttachmentKind::Selection,
            label,
            page.route.clone(),
            content,
            serde_json::to_string(&page).ok(),
        )
    }

    fn add_snapshot(
        &mut self,
        kind: ContextAttachmentKind,
        label: String,
        source: String,
        content: String,
        page_snapshot: Option<String>,
    ) -> InlineToken {
        let id = format!("{SNAPSHOT_PREFIX}{}", uuid::Uuid::new_v4().simple());
        let token = snapshot_token(&id, &label);
        self.snapshots.insert(
            id.clone(),
            ContextAttachment {
                id,
                label,
                kind,
                source,
                content,
                page_snapshot,
            },
        );
        token
    }

    pub(crate) fn disable_auto(&mut self) {
        self.auto_initialized = true;
    }

    pub(crate) fn labels(&self) -> ContextLabels {
        ContextLabels(
            self.snapshots
                .iter()
                .map(|(id, item)| {
                    (
                        id.clone(),
                        (
                            item.label.clone(),
                            format!("{}\nSaved context snapshot", item.source),
                        ),
                    )
                })
                .collect(),
        )
    }

    pub(crate) fn source(&self, id: &str) -> Option<PageContext> {
        self.snapshots
            .get(id)?
            .page_snapshot
            .as_ref()
            .and_then(|page| serde_json::from_str(page).ok())
    }

    pub(crate) fn freeze(
        &self,
        content: &InputContent,
        current_page: Option<PageContext>,
        workspace: &Path,
        page_state: &PageContextState,
        scope: ConversationScope,
    ) -> (MessageDraft, String, Option<FrozenPageContext>) {
        let mut draft = MessageDraft::default();
        let mut cursor = 0;
        let mut page = None;
        let mut prefixes = Vec::new();
        for span in content.tokens() {
            let range = span.range();
            draft.text.push_str(&content.text()[cursor..range.start]);
            let original = span.token();
            let attachment = if original.id().as_ref() == AUTO_PAGE_TOKEN {
                current_page.clone().map(|current| {
                    let id = format!("{SNAPSHOT_PREFIX}{}", uuid::Uuid::new_v4().simple());
                    ContextAttachment {
                        id,
                        label: current.chip_title(),
                        kind: ContextAttachmentKind::Page,
                        source: current.route.clone(),
                        content: crate::page_context::context_note(&current, 20_000),
                        page_snapshot: serde_json::to_string(&current).ok(),
                    }
                })
            } else if let Some(snapshot) = self.snapshots.get(original.id().as_ref()) {
                Some(snapshot.clone())
            } else {
                Mention::parse_token_id(original.id()).and_then(|mention| {
                    mention
                        .prompt_context(workspace)
                        .map(|text| ContextAttachment {
                            id: original.id().to_string(),
                            label: mention.chip_label(),
                            kind: if matches!(mention, Mention::File { .. }) {
                                ContextAttachmentKind::File
                            } else {
                                ContextAttachmentKind::Skill
                            },
                            source: mention.tooltip(workspace),
                            content: text,
                            page_snapshot: None,
                        })
                })
            };
            let token = if let Some(attachment) = attachment {
                if attachment.kind == ContextAttachmentKind::Page && page.is_none() {
                    page = attachment
                        .page_snapshot
                        .as_ref()
                        .and_then(|snapshot| serde_json::from_str(snapshot).ok());
                } else {
                    prefixes.push(attachment.content.clone());
                }
                let token = if attachment.id.starts_with(SNAPSHOT_PREFIX) {
                    let mut token = snapshot_token(&attachment.id, &attachment.label);
                    if original.text().ends_with(' ') {
                        token =
                            InlineToken::new(attachment.id.clone(), format!("{} ", token.text()))
                                .with_label(attachment.label.clone());
                    }
                    token
                } else {
                    original.clone()
                };
                draft.attachments.push(attachment);
                token
            } else if original.id().as_ref() == AUTO_PAGE_TOKEN {
                cursor = range.end;
                continue;
            } else {
                original.clone()
            };
            let start = draft.text.len();
            draft.text.push_str(token.text());
            draft.tokens.push(DraftToken {
                range: start..draft.text.len(),
                id: token.id().to_string(),
                text: token.text().to_string(),
                label: token.label().to_string(),
            });
            cursor = range.end;
        }
        draft.text.push_str(&content.text()[cursor..]);
        let plain_text = user_text(content);
        let mut referenced = std::collections::HashSet::new();
        for path in plain_text
            .split_whitespace()
            .filter_map(|word| word.strip_prefix('@'))
        {
            if path.is_empty() || path.starts_with('/') || !referenced.insert(path) {
                continue;
            }
            let id = format!("context:legacy-file:{path}");
            let attachment = self.snapshots.get(&id).cloned().or_else(|| {
                let mention = Mention::File { path: path.into() };
                mention
                    .prompt_context(workspace)
                    .map(|content| ContextAttachment {
                        id,
                        label: mention.chip_label(),
                        kind: ContextAttachmentKind::File,
                        source: mention.tooltip(workspace),
                        content,
                        page_snapshot: None,
                    })
            });
            if let Some(attachment) = attachment {
                prefixes.push(attachment.content.clone());
                draft.attachments.push(attachment);
            }
        }
        let mut prompt = prefixes.join("\n\n");
        if !prompt.is_empty() {
            prompt.push_str("\n\n");
        }
        prompt.push_str(&crate::mention::display_text(&draft.text));
        let (prompt, context) = page_state.freeze_page(scope, prompt, page);
        (draft, prompt, context)
    }
}

pub(crate) struct ContextLabels(HashMap<String, (String, String)>);

impl ContextLabels {
    pub(crate) fn label(&self, id: &str, page: Option<&PageContext>) -> Option<(String, String)> {
        if id == AUTO_PAGE_TOKEN {
            return Some(match page {
                Some(page) => (
                    format!("{} · Following", page.chip_title()),
                    format!("{}\nFollows the active tab until sent", page.route),
                ),
                None => (
                    "Current page unavailable".into(),
                    "Switch to a page to attach its context".into(),
                ),
            });
        }
        self.0.get(id).cloned()
    }
}

pub(crate) fn auto_page_token() -> InlineToken {
    InlineToken::new(AUTO_PAGE_TOKEN, "[@Current page](cgc-context://active) ")
        .with_label("Current page")
}

fn snapshot_token(id: &str, label: &str) -> InlineToken {
    let safe_label = label.replace(['\n', '\r', '\t'], " ");
    let encoded = url::form_urlencoded::byte_serialize(safe_label.as_bytes())
        .collect::<String>()
        .replace('+', "%20");
    InlineToken::new(
        id.to_string(),
        format!(
            "[@{encoded}](cgc-context://{})",
            id.trim_start_matches(SNAPSHOT_PREFIX)
        ),
    )
    .with_label(safe_label)
}

pub(crate) fn user_text(content: &InputContent) -> String {
    command_text(content).trim_end().to_string()
}

pub(crate) fn command_text(content: &InputContent) -> String {
    let mut text = String::new();
    let mut cursor = 0;
    for span in content.tokens() {
        let range = span.range();
        text.push_str(&content.text()[cursor..range.start]);
        if !span.token().id().starts_with("context:") {
            text.push_str(span.token().text());
        }
        cursor = range.end;
    }
    text.push_str(&content.text()[cursor..]);
    text.trim_start().to_string()
}

pub(crate) fn open_token_source(id: &str, _window: &mut Window, cx: &mut App) {
    if let Some(root) = crate::root_view::root_weak() {
        let _ = root.update(cx, |root, cx| root.open_context_source(id, cx));
    }
}

pub(crate) fn source_from_history(
    thread: &cgc_agent_ui::conversation::ConversationThread,
    id: &str,
) -> Option<PageContext> {
    thread
        .user_drafts
        .iter()
        .flatten()
        .flat_map(|draft| &draft.attachments)
        .find(|item| item.id == id)?
        .page_snapshot
        .as_ref()
        .and_then(|page| serde_json::from_str(page).ok())
}

pub(crate) fn slash_query_range(content: &InputContent) -> Option<std::ops::Range<usize>> {
    if !user_text(content).starts_with('/') {
        return None;
    }
    let start = content.text().char_indices().find_map(|(index, ch)| {
        (ch == '/'
            && !content
                .tokens()
                .iter()
                .any(|span| span.range().contains(&index)))
        .then_some(index)
    })?;
    let next_token = content
        .tokens()
        .iter()
        .map(|span| span.range().start)
        .find(|index| *index > start)
        .unwrap_or(content.text().len());
    let end = content.text()[start..next_token]
        .char_indices()
        .find_map(|(offset, ch)| ch.is_whitespace().then_some(start + offset))
        .unwrap_or(next_token);
    Some(start..end)
}

pub(crate) fn draft_for_entry(
    thread: &cgc_agent_ui::conversation::ConversationThread,
    index: usize,
) -> Option<&MessageDraft> {
    let ordinal = thread
        .entries
        .get(..=index)?
        .iter()
        .filter(|entry| matches!(entry, cgc_agent_ui::conversation::Entry::User { .. }))
        .count();
    thread.user_drafts.get(ordinal.checked_sub(1)?)?.as_ref()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page_context::PageBody;

    fn page(id: &str) -> PageContext {
        PageContext {
            workspace_id: Some("workspace-1".into()),
            tab_id: format!("tab-{id}"),
            route: format!("/courses/{id}/learn"),
            title: format!("Course {id}"),
            version: "v1".into(),
            body: PageBody::Ready(format!("Original task for {id}").into()),
            course: None,
        }
    }
    fn scope() -> ConversationScope {
        ConversationScope::new("thread-1", "native")
    }
    fn content(token: InlineToken, before: &str, after: &str) -> InputContent {
        let text = format!("{before}{}{after}", token.text());
        let end = before.len() + token.text().len();
        InputContent::new(text)
            .with_token(before.len()..end, token)
            .unwrap()
    }

    #[test]
    fn automatic_page_follows_tab_without_changing_the_draft_text() {
        let composer = ComposerContext::default();
        let input = content(auto_page_token(), "", "what is the task?");
        let before = input.clone();
        let state = PageContextState::default();
        let (_, first, _) =
            composer.freeze(&input, Some(page("A")), Path::new("."), &state, scope());
        let (saved, next, frozen) =
            composer.freeze(&input, Some(page("B")), Path::new("."), &state, scope());
        assert!(first.contains("Original task for A"));
        assert!(next.contains("Original task for B"));
        assert!(!next.contains("Original task for A"));
        assert!(next.ends_with("what is the task?"));
        assert_eq!(input, before);
        assert_eq!(user_text(&input), "what is the task?");
        assert!(saved.tokens.iter().all(|token| token.id != AUTO_PAGE_TOKEN));
        assert_eq!(frozen.unwrap().page.tab_id, "tab-B");
    }

    #[test]
    fn serialized_history_restores_original_page_and_attachment_position() {
        let state = PageContextState::default();
        let composer = ComposerContext::default();
        let input = content(auto_page_token(), "explain ", " in detail");
        let (draft, _, _) =
            composer.freeze(&input, Some(page("A")), Path::new("."), &state, scope());
        let draft: MessageDraft =
            serde_json::from_str(&serde_json::to_string(&draft).unwrap()).unwrap();
        let mut editor = ComposerContext::default();
        let restored = editor.restore(&draft);
        state.set_current(Some(page("B")));
        state.invalidate_loaded(&scope());
        let (resent, prompt, context) =
            editor.freeze(&restored, Some(page("B")), Path::new("."), &state, scope());
        assert_eq!(resent, draft);
        assert_eq!(restored.tokens()[0].range().start, "explain ".len());
        assert!(prompt.contains("Original task for A"));
        assert!(!prompt.contains("Original task for B"));
        assert_eq!(context.unwrap().page.tab_id, "tab-A");
    }

    #[test]
    fn selection_payload_survives_tab_change_and_history_restore() {
        let state = PageContextState::default();
        let mut composer = ComposerContext::default();
        let token = composer.add_selection(page("A"), "selected task only".into());
        let input = content(token, "explain ", " please");
        let (draft, prompt, context) =
            composer.freeze(&input, Some(page("B")), Path::new("."), &state, scope());
        assert!(prompt.contains("selected task only"));
        assert!(!prompt.contains("Original task for B"));
        assert!(context.is_none());
        let mut editor = ComposerContext::default();
        let restored = editor.restore(&draft);
        let (_, resent, _) =
            editor.freeze(&restored, Some(page("B")), Path::new("."), &state, scope());
        assert_eq!(resent, prompt);
        assert_eq!(draft.attachments[0].kind, ContextAttachmentKind::Selection);
    }

    #[test]
    fn removed_page_token_never_silently_attaches_the_current_tab() {
        let state = PageContextState::default();
        let composer = ComposerContext::default();
        let (draft, prompt, context) = composer.freeze(
            &InputContent::new("question"),
            Some(page("B")),
            Path::new("."),
            &state,
            scope(),
        );
        assert_eq!(prompt, "question");
        assert!(draft.attachments.is_empty());
        assert!(context.is_none());
        let (draft, _, _) = composer.freeze(
            &content(auto_page_token(), "", ""),
            Some(page("B")),
            Path::new("."),
            &state,
            scope(),
        );
        assert_eq!(draft.attachments.len(), 1);
        assert!(user_text(&content(auto_page_token(), "", "")).is_empty());
    }

    #[test]
    fn slash_completion_preserves_context_tokens_and_ignores_their_uri() {
        let input = content(auto_page_token(), "", "/explain");
        let range = slash_query_range(&input).unwrap();
        assert_eq!(&input.text()[range.clone()], "/explain");
        assert_eq!(range.start, auto_page_token().text().len());
        assert_eq!(
            slash_query_range(&content(auto_page_token(), "", "question /detail")),
            None
        );
        assert_eq!(slash_query_range(&content(auto_page_token(), "", "")), None);
        assert_eq!(
            command_text(&content(auto_page_token(), "", "/explain ")),
            "/explain "
        );
        let mut composer = ComposerContext::default();
        let selection = composer.add_selection(page("A"), "selected task".into());
        let input = content(selection, "/explain ", "");
        let range = slash_query_range(&input).unwrap();
        assert_eq!(&input.text()[range.clone()], "/explain");
        assert!(range.end < input.tokens()[0].range().start);
    }

    #[test]
    fn manual_file_references_keep_their_snapshot_after_source_changes() {
        let root = std::env::temp_dir().join(format!(
            "cgc-composer-file-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("notes.md"), "original file body").unwrap();
        let state = PageContextState::default();
        let composer = ComposerContext::default();
        let (draft, prompt, _) = composer.freeze(
            &InputContent::new("read @notes.md"),
            None,
            &root,
            &state,
            scope(),
        );
        assert!(prompt.contains("original file body"));
        std::fs::write(root.join("notes.md"), "changed file body").unwrap();
        let mut editor = ComposerContext::default();
        let restored = editor.restore(&draft);
        let (_, prompt, _) = editor.freeze(&restored, None, &root, &state, scope());
        assert!(prompt.contains("original file body"));
        assert!(!prompt.contains("changed file body"));
        let (removed, prompt, _) = editor.freeze(
            &InputContent::new("read the page instead"),
            None,
            &root,
            &state,
            scope(),
        );
        assert!(removed.attachments.is_empty());
        assert_eq!(prompt, "read the page instead");
        std::fs::remove_dir_all(root).unwrap();
    }
}
