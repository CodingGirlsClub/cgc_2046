//! 应用内领域事件总线（story 3.5）。
//!
//! 支付成功等跨 feature 失效经这里广播：events 列表、课程入口等订阅方自行失效
//! 重取；v1 只提供内存总线（测试可观察），后续 epic-6 的本地通知/深链再挂接。

use std::sync::Mutex;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AppEvent {
    /// 报名状态变化（支付成功/取消）：相关列表与课程入口需要重新取数。
    EnrollmentChanged {
        enrollment_id: String,
        event_id: Option<String>,
        course_id: Option<String>,
    },
    /// 课程出现待复习目标（story 4.11）；投递/通知归 epic-6，这里只发出。
    ReviewQueueDue {
        user_id: String,
        course_id: String,
        dedup_key: String,
    },
}

pub trait EventPublisher: Send + Sync {
    fn publish(&self, event: AppEvent);
}

/// 内存事件总线：记录事件供测试/调试，不持久化。
#[derive(Default)]
pub struct MemoryEventBus {
    events: Mutex<Vec<AppEvent>>,
}

impl MemoryEventBus {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn events(&self) -> Vec<AppEvent> {
        self.events.lock().expect("events lock").clone()
    }

    pub fn clear(&self) {
        self.events.lock().expect("events lock").clear();
    }
}

impl EventPublisher for MemoryEventBus {
    fn publish(&self, event: AppEvent) {
        self.events.lock().expect("events lock").push(event);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn published_events_are_observable_in_order() {
        let bus = MemoryEventBus::new();
        bus.publish(AppEvent::EnrollmentChanged {
            enrollment_id: "enr-1".into(),
            event_id: Some("evt-1".into()),
            course_id: None,
        });
        bus.publish(AppEvent::EnrollmentChanged {
            enrollment_id: "enr-2".into(),
            event_id: None,
            course_id: Some("crs-1".into()),
        });
        assert_eq!(bus.events().len(), 2);
        assert_eq!(
            bus.events()[1],
            AppEvent::EnrollmentChanged {
                enrollment_id: "enr-2".into(),
                event_id: None,
                course_id: Some("crs-1".into()),
            }
        );
        bus.publish(AppEvent::ReviewQueueDue {
            user_id: "u-1".into(),
            course_id: "crs-1".into(),
            dedup_key: "review:u-1:crs-1:obj-1@2026-10-20".into(),
        });
        assert_eq!(bus.events().len(), 3);
        bus.clear();
        assert!(bus.events().is_empty());
    }
}
