//! Issue 卡底部的 Notes section；数据来自服务端内存快照，不落本地。

use super::super::super::*;
use super::super::ScreenContext;
use crate::root_view::state::NotesFilter;
use cgc_courses::notes::{CourseNote, NoteKind, NotesState};
use gpui_kit::component::button::ButtonVariants as _;
use gpui_kit::component::input::Input;

pub(in crate::root_view) fn issue_notes_section(
    ctx: &mut ScreenContext<'_>,
    issue_id: &str,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    // Notes panel 打开时由 panel 统一承载笔记与编辑框；Issue 卡再渲染一份会让
    // 同一个 InputState 同时挂到两个视图，聚焦时 GPUI 触发重复 set_focus。
    if ctx.right_panel_open && ctx.right_panel == RightPanel::Notes {
        return div().into_any_element();
    }

    let notes = ctx
        .notes
        .notes_for_issue(issue_id)
        .into_iter()
        .cloned()
        .collect::<Vec<_>>();
    let count = notes.len();
    let state = ctx.notes.state().clone();
    let notice = ctx.notes_notice.clone();
    let root = cx.entity().downgrade();

    let mut rows = Vec::new();
    if let Some(notice) = notice {
        rows.push(
            div()
                .id("issue-notes-notice")
                .test_support()
                .text_size(px(11.0))
                .text_color(palette.accent_strong)
                .child(notice)
                .into_any_element(),
        );
    }

    rows.extend(match state {
        NotesState::Idle | NotesState::Loading => vec![div()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesLearningNotesLoading))
            .into_any_element()],
        NotesState::Failed(_error) => {
            let root = cx.entity().downgrade();
            vec![div()
                .flex()
                .flex_row()
                .items_center()
                .gap(space(1))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.danger)
                        .child(translate(language, Key::CoursesLearningNotesFailed)),
                )
                .child(
                    Button::new("issue-notes-retry")
                        .xsmall()
                        .ghost()
                        .label(translate(language, Key::CoursesLearningNotesRetry))
                        .on_click(move |_, _, cx| {
                            let _ = root.update(cx, |this, cx| this.retry_notes(cx));
                        }),
                )
                .into_any_element()]
        }
        NotesState::Empty => vec![div()
            .id("issue-notes-empty")
            .test_support()
            .text_size(px(12.0))
            .text_color(palette.ink_3)
            .child(translate(language, Key::CoursesLearningNotesEmpty))
            .into_any_element()],
        NotesState::Ready => {
            let mut grouped: Vec<(NoteTimeBucket, Vec<&CourseNote>)> = Vec::new();
            for note in &notes {
                let bucket = NoteTimeBucket::from_timestamp(&note.created_at);
                if grouped.last().map(|(last, _)| *last) != Some(bucket) {
                    grouped.push((bucket, Vec::new()));
                }
                grouped.last_mut().expect("group exists").1.push(note);
            }

            let mut elements = Vec::new();
            for (bucket, notes) in grouped {
                elements.push(
                    div()
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(bucket.label(language))
                        .into_any_element(),
                );
                elements.extend(
                    notes
                        .into_iter()
                        .map(|note| note_row(ctx, note, language, palette, cx)),
                );
            }
            elements
        }
    });

    div()
        .id("issue-notes")
        .test_support()
        .flex()
        .flex_col()
        .gap(px(6.0))
        .pt(px(4.0))
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_size(px(11.0))
                        .text_color(palette.accent_strong)
                        .child(translate(language, Key::CoursesLearningNotes)),
                )
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(px(6.0))
                        .child(
                            div()
                                .text_size(px(10.0))
                                .text_color(palette.ink_3)
                                .child(format!("{count}")),
                        )
                        .child(
                            Button::new("issue-notes-view-all")
                                .xsmall()
                                .ghost()
                                .label(translate(language, Key::CoursesLearningNotesViewAll))
                                .on_click(move |_, _, cx| {
                                    let _ = root.update(cx, |this, cx| {
                                        this.open_notes_panel(cx);
                                    });
                                }),
                        ),
                ),
        )
        .children(rows)
        .into_any_element()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum NoteTimeBucket {
    Today,
    Yesterday,
    Earlier,
}

impl NoteTimeBucket {
    fn from_timestamp(value: &str) -> Self {
        let Ok(timestamp) = chrono::DateTime::parse_from_rfc3339(value) else {
            return Self::Earlier;
        };
        let date = timestamp.date_naive();
        let today = chrono::Utc::now().date_naive();
        match (today - date).num_days() {
            0 => Self::Today,
            1 => Self::Yesterday,
            _ => Self::Earlier,
        }
    }

    fn label(self, language: Language) -> &'static str {
        translate(
            language,
            match self {
                Self::Today => Key::CoursesLearningNotesToday,
                Self::Yesterday => Key::CoursesLearningNotesYesterday,
                Self::Earlier => Key::CoursesLearningNotesEarlier,
            },
        )
    }
}

fn note_row(
    ctx: &mut ScreenContext<'_>,
    note: &CourseNote,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let kind_label = match note.kind {
        NoteKind::Note => translate(language, Key::CoursesLearningNotesNote),
        NoteKind::Retro => translate(language, Key::CoursesLearningNotesRetro),
    };
    let source = note
        .source_material_id
        .as_deref()
        .and_then(|material_id| material_title(ctx, &note.issue_id, material_id))
        .unwrap_or_else(|| translate(language, Key::CoursesLearningNotesSourceIssue).to_string());
    let editing = ctx
        .note_edit
        .as_ref()
        .filter(|edit| edit.note_id == note.id)
        .map(|edit| edit.input.clone());
    let pending_delete = ctx.note_pending_delete.as_deref() == Some(note.id.as_str());
    let root = cx.entity().downgrade();

    let mut row = div()
        .id(SharedString::from(format!("issue-note-{}", note.id)))
        .test_support()
        .flex()
        .flex_col()
        .gap(px(3.0))
        .p(space(1))
        .rounded(px(RADIUS_SMALL))
        .border_1()
        .border_color(palette.line)
        .bg(palette.card)
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(6.0))
                .child(
                    div()
                        .px(px(4.0))
                        .rounded(px(3.0))
                        .bg(palette.soft)
                        .text_size(px(9.0))
                        .text_color(palette.accent_strong)
                        .child(kind_label),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.0))
                        .text_size(px(10.0))
                        .text_color(palette.ink_3)
                        .child(source.to_string()),
                )
                .child(
                    div()
                        .text_size(px(9.0))
                        .text_color(palette.ink_3)
                        .child(note.created_at.clone()),
                ),
        );

    if let Some(input) = editing {
        let root_for_save = root.clone();
        let root_for_cancel = root.clone();
        row = row.child(Input::new(&input).small().w_full()).child(
            div()
                .flex()
                .flex_row()
                .gap(px(4.0))
                .child(
                    Button::new(SharedString::from(format!("note-save-{}", note.id)))
                        .xsmall()
                        .label(translate(language, Key::CoursesLearningNotesSave))
                        .on_click(move |_, _, cx| {
                            let _ = root_for_save.update(cx, |this, cx| this.save_note_edit(cx));
                        }),
                )
                .child(
                    Button::new(SharedString::from(format!("note-cancel-{}", note.id)))
                        .xsmall()
                        .ghost()
                        .label(translate(language, Key::CoursesLearningNotesCancel))
                        .on_click(move |_, _, cx| {
                            let _ =
                                root_for_cancel.update(cx, |this, cx| this.cancel_note_edit(cx));
                        }),
                ),
        );
    } else {
        let expanded = ctx.expanded_notes.contains(&note.id);
        let is_long = note.text.chars().count() > 360;
        let display = if is_long && !expanded {
            format!("{}…", note.text.chars().take(360).collect::<String>())
        } else {
            note.text.clone()
        };
        row = row.child(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink)
                .child(display),
        );
        if is_long {
            let root_for_expand = root.clone();
            let note_id = note.id.clone();
            row = row.child(
                Button::new(SharedString::from(format!("note-expand-{}", note.id)))
                    .xsmall()
                    .ghost()
                    .label(translate(
                        language,
                        if expanded {
                            Key::CoursesLearningNotesCollapse
                        } else {
                            Key::CoursesLearningNotesExpand
                        },
                    ))
                    .on_click(move |_, _, cx| {
                        let _ = root_for_expand.update(cx, |this, cx| {
                            if !this.expanded_notes.remove(&note_id) {
                                this.expanded_notes.insert(note_id.clone());
                            }
                            cx.notify();
                        });
                    }),
            );
        }

        if pending_delete {
            let root_for_confirm = root.clone();
            let root_for_cancel = root.clone();
            let note_id = note.id.clone();
            row = row.child(
                div()
                    .flex()
                    .flex_row()
                    .gap(px(4.0))
                    .child(
                        Button::new(SharedString::from(format!("note-confirm-{}", note.id)))
                            .xsmall()
                            .label(translate(language, Key::CoursesLearningNotesConfirmDelete))
                            .on_click(move |_, _, cx| {
                                let _ = root_for_confirm
                                    .update(cx, |this, cx| this.confirm_delete_note(&note_id, cx));
                            }),
                    )
                    .child(
                        Button::new(SharedString::from(format!(
                            "note-cancel-delete-{}",
                            note.id
                        )))
                        .xsmall()
                        .ghost()
                        .label(translate(language, Key::CoursesLearningNotesCancel))
                        .on_click(move |_, _, cx| {
                            let _ =
                                root_for_cancel.update(cx, |this, cx| this.cancel_delete_note(cx));
                        }),
                    ),
            );
        } else {
            let root_for_edit = root.clone();
            let root_for_copy = root.clone();
            let root_for_delete = root.clone();
            let root_for_send = root.clone();
            let note_for_edit = note.clone();
            let note_for_send = note.clone();
            let note_id = note.id.clone();
            let copy_text = note.text.clone();
            row = row.child(
                div()
                    .flex()
                    .flex_row()
                    .flex_wrap()
                    .gap(px(2.0))
                    .child(
                        Button::new(SharedString::from(format!("note-edit-{}", note.id)))
                            .xsmall()
                            .ghost()
                            .label(translate(language, Key::CoursesLearningNotesEdit))
                            .on_click(move |_, window, cx| {
                                let _ = root_for_edit.update(cx, |this, cx| {
                                    this.begin_note_edit(&note_for_edit, window, cx)
                                });
                            }),
                    )
                    .child(
                        Button::new(SharedString::from(format!("note-copy-{}", note.id)))
                            .xsmall()
                            .ghost()
                            .label(translate(language, Key::CoursesLearningNotesCopy))
                            .on_click(move |_, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(copy_text.clone()));
                                let _ = root_for_copy.update(cx, |this, cx| {
                                    this.notes_notice = Some(
                                        translate(this.language, Key::CoursesLearningNotesCopied)
                                            .into(),
                                    );
                                    cx.notify();
                                });
                            }),
                    )
                    .child(
                        Button::new(SharedString::from(format!("note-delete-{}", note.id)))
                            .xsmall()
                            .ghost()
                            .label(translate(language, Key::CoursesLearningNotesDelete))
                            .on_click(move |_, _, cx| {
                                let _ = root_for_delete
                                    .update(cx, |this, cx| this.request_delete_note(&note_id, cx));
                            }),
                    )
                    .child(
                        Button::new(SharedString::from(format!("note-send-{}", note.id)))
                            .xsmall()
                            .ghost()
                            .label(translate(language, Key::CoursesLearningNotesSendAgent))
                            .on_click(move |_, window, cx| {
                                let _ = root_for_send.update(cx, |this, cx| {
                                    this.send_note_to_agent(&note_for_send, window, cx)
                                });
                            }),
                    ),
            );
        }
    }

    row.into_any_element()
}

pub(in crate::root_view) fn render_course_notes(
    ctx: &mut ScreenContext<'_>,
    language: Language,
    palette: &theme::Palette,
    cx: &mut Context<RootView>,
) -> AnyElement {
    let all_notes = ctx.notes.notes().to_vec();
    let filter = ctx.notes_filter;
    let filtered = all_notes
        .iter()
        .filter(|note| match filter {
            NotesFilter::All => true,
            NotesFilter::Notes => note.kind == NoteKind::Note,
            NotesFilter::Retro => note.kind == NoteKind::Retro,
        })
        .cloned()
        .collect::<Vec<_>>();

    let mut groups: std::collections::BTreeMap<String, Vec<CourseNote>> =
        std::collections::BTreeMap::new();
    for note in filtered {
        groups.entry(note.issue_id.clone()).or_default().push(note);
    }

    let root = cx.entity().downgrade();
    let filter_button = |id: &'static str, label_key, active: bool, filter: NotesFilter| {
        let root = root.clone();
        let _ = active;
        Button::new(id)
            .xsmall()
            .ghost()
            .label(translate(language, label_key))
            .on_click(move |_, _, cx| {
                let _ = root.update(cx, |this, cx| {
                    this.notes_filter = filter;
                    cx.notify();
                });
            })
    };

    let mut content = Vec::new();
    content.push(
        div()
            .flex()
            .flex_row()
            .gap(px(4.0))
            .child(filter_button(
                "notes-filter-all",
                Key::CoursesLearningNotesFilterAll,
                filter == NotesFilter::All,
                NotesFilter::All,
            ))
            .child(filter_button(
                "notes-filter-notes",
                Key::CoursesLearningNotesFilterNotes,
                filter == NotesFilter::Notes,
                NotesFilter::Notes,
            ))
            .child(filter_button(
                "notes-filter-retro",
                Key::CoursesLearningNotesFilterRetro,
                filter == NotesFilter::Retro,
                NotesFilter::Retro,
            ))
            .into_any_element(),
    );

    match ctx.notes.state().clone() {
        NotesState::Idle | NotesState::Loading => content.push(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningNotesLoading))
                .into_any_element(),
        ),
        NotesState::Failed(_) => {
            let root = cx.entity().downgrade();
            content.push(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .child(
                        div()
                            .text_size(px(12.0))
                            .text_color(palette.danger)
                            .child(translate(language, Key::CoursesLearningNotesFailed)),
                    )
                    .child(
                        Button::new("notes-panel-retry")
                            .xsmall()
                            .label(translate(language, Key::CoursesLearningNotesRetry))
                            .on_click(move |_, _, cx| {
                                let _ = root.update(cx, |this, cx| this.retry_notes(cx));
                            }),
                    )
                    .into_any_element(),
            );
        }
        NotesState::Empty => content.push(
            div()
                .text_size(px(12.0))
                .text_color(palette.ink_3)
                .child(translate(language, Key::CoursesLearningNotesEmpty))
                .into_any_element(),
        ),
        NotesState::Ready => {
            if groups.is_empty() {
                content.push(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink_3)
                        .child(translate(language, Key::CoursesLearningNotesEmpty))
                        .into_any_element(),
                );
            } else {
                for (issue_id, notes) in groups {
                    content.push(
                        div()
                            .text_size(px(11.0))
                            .text_color(palette.accent_strong)
                            .child(issue_title(ctx, &issue_id).unwrap_or(issue_id.clone()))
                            .into_any_element(),
                    );
                    content.extend(
                        notes
                            .iter()
                            .map(|note| note_row(ctx, note, language, palette, cx)),
                    );
                }
            }
        }
    }

    div()
        .id("course-notes-panel")
        .test_support()
        .flex()
        .flex_col()
        .gap(px(6.0))
        .p(space(2))
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .justify_between()
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(palette.ink)
                        .child(translate(language, Key::CoursesLearningNotesPanelTitle)),
                )
                .child(
                    div().text_size(px(10.0)).text_color(palette.ink_3).child(
                        translate(language, Key::CoursesLearningNotesCount)
                            .replace("{count}", &ctx.notes.notes().len().to_string()),
                    ),
                ),
        )
        .children(content)
        .into_any_element()
}

fn issue_title(ctx: &ScreenContext<'_>, issue_id: &str) -> Option<String> {
    ctx.content
        .content()?
        .document
        .issues
        .iter()
        .find(|issue| issue.id.as_deref() == Some(issue_id))
        .and_then(|issue| issue.title.clone())
}

fn material_title(ctx: &ScreenContext<'_>, issue_id: &str, material_id: &str) -> Option<String> {
    let document = &ctx.content.content()?.document;
    let issue = document
        .issues
        .iter()
        .find(|issue| issue.id.as_deref() == Some(issue_id))?;

    issue
        .story_materials
        .iter()
        .chain(issue.objective_materials.iter())
        .find(|material| material.id.as_deref() == Some(material_id))
        .and_then(|material| material.title.clone().or_else(|| material.alt_text.clone()))
}
