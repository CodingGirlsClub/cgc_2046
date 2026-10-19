//! 运行期词表与语言切换（story 1.3）。
//!
//! 词表源文件在 `desktop/resources/i18n/{zh,en}.lang`，`build.rs` 在构建期校验
//! 键集合与命名并生成目录常量；本模块只做查表与语言状态，不重复校验。

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

/// 查询文案；key 必须已被 build.rs 与注册校验覆盖，缺失视为代码与词表漂移，直接 panic。
pub fn translate(language: Language, key: &str) -> &'static str {
    language
        .catalog()
        .iter()
        .find(|(candidate, _)| *candidate == key)
        .map(|(_, value)| *value)
        .unwrap_or_else(|| panic!("missing i18n key `{key}` (locale `{}`)", language.code()))
}

/// 默认语言：`CGC_LANG=zh|en` 环境变量优先，否则中文（v1 主要用户）。
pub fn default_language() -> Language {
    std::env::var("CGC_LANG")
        .ok()
        .and_then(|code| Language::from_code(code.trim()))
        .unwrap_or(Language::Zh)
}

/// 系统词表里是否存在该 key（供注册校验使用，避免 panic 路径）。
pub fn has_key(language: Language, key: &str) -> bool {
    language
        .catalog()
        .iter()
        .any(|(candidate, _)| *candidate == key)
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
    fn every_key_resolves_in_every_locale() {
        for language in Language::ALL {
            for (key, _) in language.catalog() {
                assert_eq!(translate(language, key), translate(language, key));
            }
        }
    }

    #[test]
    fn toggling_language_changes_translation_immediately() {
        let zh = translate(Language::Zh, "app.empty.title");
        let en = translate(Language::En, "app.empty.title");
        assert_ne!(zh, en);
        assert_eq!(Language::Zh.toggle().toggle(), Language::Zh);
    }

    #[test]
    #[should_panic(expected = "missing i18n key `nope.missing.key`")]
    fn unknown_key_panics_with_diagnostic() {
        translate(Language::Zh, "nope.missing.key");
    }

    #[test]
    fn language_code_round_trips() {
        for language in Language::ALL {
            assert_eq!(Language::from_code(language.code()), Some(language));
        }
        assert_eq!(Language::from_code("fr"), None);
    }
}
