//! 运行期词表与语言切换（story 1.3）。
//!
//! 真源在 `desktop/resources/i18n/`：`keys.txt` 是必需 key 清单，`{zh,en}.lang` 是词表。
//! `build.rs` 在构建期校验三者一致（缺 key、未登记 key、重复、非法命名、空值都失败），
//! 并生成强类型 `Key` 枚举——代码只能引用已登记的 key，双表同删会直接编译失败。

include!(concat!(env!("OUT_DIR"), "/i18n_catalog.rs"));

/// 支持的语言；新增语言时同时补 `resources/i18n/<code>.lang` 与 build.rs 的 LOCALES。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Language {
    Zh,
    En,
}

impl Language {
    pub const ALL: [Language; 2] = [Language::Zh, Language::En];

    pub fn code(self) -> &'static str {
        match self {
            Language::Zh => "zh",
            Language::En => "en",
        }
    }

    pub fn from_code(code: &str) -> Option<Self> {
        match code {
            "zh" => Some(Language::Zh),
            "en" => Some(Language::En),
            _ => None,
        }
    }

    pub fn toggle(self) -> Self {
        match self {
            Language::Zh => Language::En,
            Language::En => Language::Zh,
        }
    }

    pub fn catalog(self) -> &'static [(&'static str, &'static str)] {
        match self {
            Language::Zh => ZH,
            Language::En => EN,
        }
    }
}

/// 按已登记 key 查文案；缺失视为代码与词表漂移，直接 panic（构建期已挡住该类错误）。
pub fn translate(language: Language, key: Key) -> &'static str {
    lookup(language, key.as_str()).unwrap_or_else(|| {
        panic!(
            "missing i18n key `{}` (locale `{}`)",
            key.as_str(),
            language.code()
        )
    })
}

/// 按字符串 key 查文案，供路由标题等运行期注册数据使用；缺失同样 panic 并指出 key。
pub fn translate_registered(language: Language, key: &str) -> &'static str {
    lookup(language, key).unwrap_or_else(|| {
        panic!(
            "missing registered i18n key `{key}` (locale `{}`)",
            language.code()
        )
    })
}

/// 查表但返回 Option，供注册校验使用（避免走 panic 路径）。
pub fn lookup(language: Language, key: &str) -> Option<&'static str> {
    language
        .catalog()
        .iter()
        .find(|(candidate, _)| *candidate == key)
        .map(|(_, value)| *value)
}

/// 系统词表里是否存在该 key（供注册校验与测试使用）。
pub fn has_key(language: Language, key: &str) -> bool {
    lookup(language, key).is_some()
}

/// 解析语言值；纯函数，单测不写进程环境变量。
pub fn language_from_value(value: Option<&str>) -> Language {
    value
        .and_then(|code| Language::from_code(code.trim()))
        .unwrap_or(Language::Zh)
}

/// 默认语言：`CGC_LANG=zh|en` 环境变量优先，否则中文（v1 主要用户）。
pub fn default_language() -> Language {
    let value = std::env::var("CGC_LANG").ok();
    language_from_value(value.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locales_cover_the_same_keys() {
        let zh: Vec<_> = Language::Zh.catalog().iter().map(|(k, _)| *k).collect();
        let en: Vec<_> = Language::En.catalog().iter().map(|(k, _)| *k).collect();
        assert_eq!(zh, en, "zh/en key sets must match");
    }

    #[test]
    fn every_registered_key_resolves_in_every_locale() {
        for language in Language::ALL {
            for key in Key::ALL {
                let value = translate(language, *key);
                assert!(
                    !value.is_empty(),
                    "empty value for `{}` ({})",
                    key.as_str(),
                    language.code()
                );
                assert_eq!(
                    lookup(language, key.as_str()),
                    Some(value),
                    "lookup disagrees with translate for `{}`",
                    key.as_str()
                );
                assert_eq!(
                    key.as_str(),
                    Language::Zh
                        .catalog()
                        .iter()
                        .find(|(candidate, _)| *candidate == key.as_str())
                        .map(|(candidate, _)| *candidate)
                        .expect("key registered in catalog")
                );
            }
        }
    }

    #[test]
    fn key_as_str_is_unique_and_registered() {
        let mut seen = std::collections::BTreeSet::new();
        for key in Key::ALL {
            assert!(seen.insert(key.as_str()), "duplicate key string");
            for language in Language::ALL {
                assert!(has_key(language, key.as_str()));
            }
        }
    }

    #[test]
    fn toggling_language_changes_translation_immediately() {
        let zh = translate(Language::Zh, Key::AppEmptyTitle);
        let en = translate(Language::En, Key::AppEmptyTitle);
        assert_ne!(zh, en);
        assert_eq!(Language::Zh.toggle().toggle(), Language::Zh);
    }

    #[test]
    #[should_panic(expected = "missing registered i18n key `nope.missing.key`")]
    fn unknown_registered_key_panics_with_diagnostic() {
        translate_registered(Language::Zh, "nope.missing.key");
    }

    #[test]
    fn language_env_value_is_parsed() {
        assert_eq!(super::language_from_value(Some("zh")), Language::Zh);
        assert_eq!(super::language_from_value(Some("en")), Language::En);
        assert_eq!(super::language_from_value(Some("en ")), Language::En);
        assert_eq!(super::language_from_value(Some("fr")), Language::Zh);
        assert_eq!(super::language_from_value(None), Language::Zh);
    }

    #[test]
    fn language_code_round_trips() {
        for language in Language::ALL {
            assert_eq!(Language::from_code(language.code()), Some(language));
        }
        assert_eq!(Language::from_code("fr"), None);
    }
}
