//! 详情页返回文案：公开面与工作区面用不同的可读文案。
//!
//! 放在独立模块里而不是 `screens/**` 内联测试：screens 经 `use gpui_kit::*`
//! 引入了 gpui_kit 的 `test` 名字，内联 `#[test]` 会解析到错误的宏。

use crate::i18n::Key;

pub(in crate::root_view) struct SiteTreeEntrySpec {
    pub key: Key,
    pub path: &'static str,
    pub icon: gpui_kit::assets::IconName,
}

/// 工作区组顶层条目的期望顺序（规格，渲染实现需与之一致）。
#[cfg(test)]
pub(in crate::root_view) const SITE_TREE_WORKSPACE_ENTRIES: &[Key] = &[
    Key::AccountWorkspaceOverview,
    Key::NavAgents,
    Key::EventsListTitle,
    Key::CoursesCatalogTitle,
];

pub(in crate::root_view) const SITE_TREE_MINE: &[SiteTreeEntrySpec] = &[
    SiteTreeEntrySpec {
        key: Key::EventsParticipationsTitle,
        path: "/participations",
        icon: gpui_kit::assets::IconName::Ticket,
    },
    SiteTreeEntrySpec {
        key: Key::CoursesLearningHomeTitle,
        path: "/learning",
        icon: gpui_kit::assets::IconName::GraduationCap,
    },
];

pub(in crate::root_view) const SITE_TREE_COMMUNITY: &[SiteTreeEntrySpec] = &[
    SiteTreeEntrySpec {
        key: Key::EventsPublicTitle,
        path: "/events",
        icon: gpui_kit::assets::IconName::Calendar,
    },
    SiteTreeEntrySpec {
        key: Key::CoursesPublicTitle,
        path: "/courses",
        icon: gpui_kit::assets::IconName::BookOpen,
    },
];

pub(in crate::root_view) fn enrollment_badge_key(badge: &str) -> Option<Key> {
    match badge {
        "enrolling" => Some(Key::EnrollmentBadgeEnrolling),
        "starting_soon" => Some(Key::EnrollmentBadgeStartingSoon),
        "closed" => Some(Key::EnrollmentBadgeClosed),
        "full" => Some(Key::EnrollmentBadgeFull),
        _ => None,
    }
}

pub(in crate::root_view) fn event_detail_back_key(route_id: &str) -> Key {
    if route_id == "events.public_detail" {
        Key::EventsPublicDetailBack
    } else {
        Key::EventsDetailBack
    }
}

pub(in crate::root_view) fn course_detail_back_key(route_id: &str) -> Key {
    if route_id == "courses.public_detail" {
        Key::CoursesPublicDetailBack
    } else {
        Key::CoursesDetailBack
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn site_tree_groups_match_web_order() {
        assert_eq!(
            SITE_TREE_WORKSPACE_ENTRIES,
            &[
                Key::AccountWorkspaceOverview,
                Key::NavAgents,
                Key::EventsListTitle,
                Key::CoursesCatalogTitle,
            ]
        );
        assert_eq!(SITE_TREE_MINE[0].key, Key::EventsParticipationsTitle);
        assert_eq!(SITE_TREE_MINE[1].key, Key::CoursesLearningHomeTitle);
        assert_eq!(SITE_TREE_COMMUNITY[0].key, Key::EventsPublicTitle);
        assert_eq!(SITE_TREE_COMMUNITY[1].key, Key::CoursesPublicTitle);
        assert_eq!(SITE_TREE_MINE[0].path, "/participations");
        assert_eq!(SITE_TREE_MINE[1].path, "/learning");
        assert_eq!(SITE_TREE_COMMUNITY[0].path, "/events");
        assert_eq!(SITE_TREE_COMMUNITY[1].path, "/courses");
    }

    #[test]
    fn enrollment_badges_map_to_web_copy() {
        assert_eq!(
            enrollment_badge_key("enrolling"),
            Some(Key::EnrollmentBadgeEnrolling)
        );
        assert_eq!(
            enrollment_badge_key("starting_soon"),
            Some(Key::EnrollmentBadgeStartingSoon)
        );
        assert_eq!(
            enrollment_badge_key("closed"),
            Some(Key::EnrollmentBadgeClosed)
        );
        assert_eq!(enrollment_badge_key("full"), Some(Key::EnrollmentBadgeFull));
        assert_eq!(enrollment_badge_key("unknown"), None);
    }

    #[test]
    fn public_details_use_public_back_copy() {
        assert_eq!(
            event_detail_back_key("events.public_detail"),
            Key::EventsPublicDetailBack
        );
        assert_eq!(
            event_detail_back_key("events.detail"),
            Key::EventsDetailBack
        );
        assert_eq!(
            course_detail_back_key("courses.public_detail"),
            Key::CoursesPublicDetailBack
        );
        assert_eq!(
            course_detail_back_key("courses.detail"),
            Key::CoursesDetailBack
        );
    }
}
