//! 通知中心的纯数据逻辑：分页合并、过滤、角标和时间展示。

use cgc_platform::notifications::Notification;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum NotificationFilter {
    #[default]
    All,
    Unread,
}

/// 合并服务端分页。刷新第一页时保留已加载的旧页；加载更多时追加不重复项。
pub fn merge_notifications(
    existing: &[Notification],
    incoming: &[Notification],
    append: bool,
) -> Vec<Notification> {
    let mut result = if append {
        existing.to_vec()
    } else {
        incoming.to_vec()
    };
    let incoming_ids = incoming
        .iter()
        .map(|item| item.id.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if !append {
        for item in existing {
            if !incoming_ids.contains(item.id.as_str()) {
                result.push(item.clone());
            }
        }
        return result;
    }
    for item in incoming {
        if let Some(existing_item) = result.iter_mut().find(|row| row.id == item.id) {
            *existing_item = item.clone();
        } else {
            result.push(item.clone());
        }
    }
    result
}

pub fn unread_count(items: &[Notification]) -> usize {
    items.iter().filter(|item| item.read_at.is_none()).count()
}

/// 角标文案；0 不显示，超过 9 显示 `9+`。
pub fn badge_text(count: usize) -> Option<String> {
    match count {
        0 => None,
        1..=9 => Some(count.to_string()),
        _ => Some("9+".to_string()),
    }
}

pub fn filtered_items(items: &[Notification], filter: NotificationFilter) -> Vec<&Notification> {
    items
        .iter()
        .filter(|item| filter == NotificationFilter::All || item.read_at.is_none())
        .collect()
}

/// 后端时间形如 `2026-10-22T10:00:00Z`；通知中心按现有事件展示习惯截到分钟。
pub fn format_time(inserted_at: &str) -> String {
    let Some(date) = inserted_at.get(..10) else {
        return inserted_at.to_string();
    };
    let Some(time) = inserted_at.get(11..16) else {
        return inserted_at.to_string();
    };
    if inserted_at.as_bytes().get(10) == Some(&b'T') {
        format!("{date} {time}")
    } else {
        inserted_at.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notification(id: &str, read: bool) -> Notification {
        Notification {
            id: id.to_string(),
            kind: "event_reminder".to_string(),
            deep_link: None,
            read_at: read.then(|| "2026-10-22T10:00:00Z".to_string()),
            inserted_at: "2026-10-22T10:00:00Z".to_string(),
            title: format!("title-{id}"),
            body: "body".to_string(),
        }
    }

    #[test]
    fn refresh_keeps_older_loaded_rows() {
        let existing = vec![notification("new", false), notification("old", true)];
        let incoming = vec![notification("new", true)];
        let merged = merge_notifications(&existing, &incoming, false);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].id, "new");
        assert!(merged[0].read_at.is_some());
        assert_eq!(merged[1].id, "old");
    }

    #[test]
    fn append_does_not_duplicate_ids() {
        let existing = vec![notification("n1", false)];
        let incoming = vec![notification("n1", true), notification("n2", false)];
        let merged = merge_notifications(&existing, &incoming, true);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0].id, "n1");
        assert!(merged[0].read_at.is_some());
        assert_eq!(merged[1].id, "n2");
    }

    #[test]
    fn unread_filter_and_badge() {
        let items = vec![
            notification("n1", false),
            notification("n2", true),
            notification("n3", false),
        ];
        assert_eq!(unread_count(&items), 2);
        assert_eq!(filtered_items(&items, NotificationFilter::Unread).len(), 2);
        assert_eq!(filtered_items(&items, NotificationFilter::All).len(), 3);
        assert_eq!(badge_text(0), None);
        assert_eq!(badge_text(2).as_deref(), Some("2"));
        assert_eq!(badge_text(12).as_deref(), Some("9+"));
    }

    #[test]
    fn formats_utc_timestamp_and_falls_back() {
        assert_eq!(format_time("2026-10-22T10:05:59Z"), "2026-10-22 10:05");
        assert_eq!(format_time("2026-10-22"), "2026-10-22");
        assert_eq!(format_time(""), "");
    }
}
