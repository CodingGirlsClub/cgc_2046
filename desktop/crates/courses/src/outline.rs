//! 课程 Outline 投影：把 `CourseContentDocument` 的章节与 issue 卡整理成
//! 可渲染的树，供 `Contextual Outline`、Site Tree 的课程分支和未来 Tab 共用。
//!
//! 规则：
//! - 有 `chapter_id` 的 issue 按章节顺序归组；
//! - 无章节的 issue 进入 `ungrouped`，不丢弃；
//! - issue 标题/ id 缺失时只做展示兜底，不改写课程内容语义。

use crate::content::{CourseContentDocument, CourseIssue};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CourseOutline {
    pub chapters: Vec<OutlineChapter>,
    pub ungrouped: Vec<OutlineIssue>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutlineChapter {
    pub id: Option<String>,
    pub title: String,
    pub issues: Vec<OutlineIssue>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutlineIssue {
    pub id: String,
    pub title: String,
    pub kind: Option<String>,
    pub goal: Option<String>,
    pub chapter_id: Option<String>,
}

impl CourseOutline {
    pub fn issue_count(&self) -> usize {
        self.chapters
            .iter()
            .map(|chapter| chapter.issues.len())
            .sum::<usize>()
            + self.ungrouped.len()
    }

    pub fn is_empty(&self) -> bool {
        self.issue_count() == 0
    }

    pub fn find_issue(&self, issue_id: &str) -> Option<&OutlineIssue> {
        self.chapters
            .iter()
            .flat_map(|chapter| chapter.issues.iter())
            .chain(self.ungrouped.iter())
            .find(|issue| issue.id == issue_id)
    }
}

/// 从课程内容构建 outline；顺序稳定，不依赖 HashMap。
pub fn build_outline(document: &CourseContentDocument) -> CourseOutline {
    let mut issues = document
        .issues
        .iter()
        .enumerate()
        .map(|(index, issue)| outline_issue(issue, index))
        .collect::<Vec<_>>();

    let mut chapters = document
        .chapters
        .iter()
        .enumerate()
        .map(|(index, chapter)| OutlineChapter {
            id: chapter.id.clone(),
            title: chapter
                .title
                .clone()
                .filter(|title| !title.trim().is_empty())
                .unwrap_or_else(|| format!("第 {} 章", index + 1)),
            issues: Vec::new(),
        })
        .collect::<Vec<_>>();

    let mut ungrouped = Vec::new();
    for issue in issues.drain(..) {
        let chapter_index = issue.chapter_id.as_deref().and_then(|chapter_id| {
            chapters
                .iter()
                .position(|chapter| chapter.id.as_deref() == Some(chapter_id))
        });
        match chapter_index {
            Some(index) => chapters[index].issues.push(issue),
            None => ungrouped.push(issue),
        }
    }

    CourseOutline {
        chapters,
        ungrouped,
    }
}

fn outline_issue(issue: &CourseIssue, index: usize) -> OutlineIssue {
    OutlineIssue {
        id: issue
            .id
            .clone()
            .filter(|id| !id.trim().is_empty())
            .unwrap_or_else(|| format!("issue-{}", index + 1)),
        title: issue
            .title
            .clone()
            .filter(|title| !title.trim().is_empty())
            .unwrap_or_else(|| "未命名卡片".to_string()),
        kind: issue.kind.clone(),
        goal: issue.goal.clone(),
        chapter_id: issue.chapter_id.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::content::{CourseChapter, CourseContentDocument, CourseIssue};

    fn issue(id: &str, chapter_id: Option<&str>) -> CourseIssue {
        CourseIssue {
            id: Some(id.to_string()),
            title: Some(format!("卡 {id}")),
            kind: Some("handwork".to_string()),
            chapter_id: chapter_id.map(str::to_string),
            goal: Some("完成练习".to_string()),
            ..Default::default()
        }
    }

    fn document() -> CourseContentDocument {
        CourseContentDocument {
            goals: vec!["目标".to_string()],
            chapters: vec![
                CourseChapter {
                    id: Some("ch-1".to_string()),
                    title: Some("第一章".to_string()),
                },
                CourseChapter {
                    id: Some("ch-2".to_string()),
                    title: None,
                },
            ],
            issues: vec![
                issue("i-1", Some("ch-1")),
                issue("i-2", None),
                issue("i-3", Some("ch-2")),
                issue("i-4", Some("missing")),
            ],
        }
    }

    #[test]
    fn groups_issues_by_chapter_and_keeps_un_grouped() {
        let outline = build_outline(&document());
        assert_eq!(outline.chapters.len(), 2);
        assert_eq!(outline.chapters[0].title, "第一章");
        assert_eq!(outline.chapters[0].issues.len(), 1);
        assert_eq!(outline.chapters[1].title, "第 2 章");
        assert_eq!(outline.chapters[1].issues.len(), 1);
        assert_eq!(outline.ungrouped.len(), 2);
        assert_eq!(outline.issue_count(), 4);
        assert!(!outline.is_empty());
    }

    #[test]
    fn missing_issue_id_gets_stable_display_fallback() {
        let mut document = document();
        document.issues[0].id = None;
        let outline = build_outline(&document);
        assert_eq!(outline.chapters[0].issues[0].id, "issue-1");
    }

    #[test]
    fn empty_document_is_empty_outline() {
        let outline = build_outline(&CourseContentDocument::default());
        assert!(outline.is_empty());
        assert!(outline.find_issue("missing").is_none());
    }
}
