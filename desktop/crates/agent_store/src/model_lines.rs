//! 模型行文本格式的解析与格式化（Settings Provider 表单使用）。

use crate::prefs::{ModelPrefs, ProviderPrefs};

/// 把 provider 的模型参数渲染为每行一模型的文本。
pub fn format_model_lines(provider: &ProviderPrefs) -> String {
    provider
        .models
        .iter()
        .map(|id| {
            let model = provider.model_config(id);
            format!(
                "{} | {} | {} | {} | {} | {}",
                id,
                model.context_window,
                model.max_output_tokens,
                model.supports_thinking,
                model.enabled,
                model.supports_tools
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// 解析模型行：`模型名 | context | max_output | thinking | enabled | tools`。
pub fn parse_model_lines(value: &str) -> (Vec<String>, Vec<ModelPrefs>) {
    let mut ids = Vec::new();
    let mut params = Vec::new();
    for line in value.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split('|').map(str::trim).collect();
        let Some(id) = parts.first().filter(|id| !id.is_empty()) else {
            continue;
        };
        let context = parts
            .get(1)
            .and_then(|value| value.parse().ok())
            .unwrap_or(64_000);
        let output = parts
            .get(2)
            .and_then(|value| value.parse().ok())
            .unwrap_or(8_000);
        let thinking = parts
            .get(3)
            .map(|value| matches!(value.to_ascii_lowercase().as_str(), "true" | "1" | "yes"))
            .unwrap_or(false);
        let enabled = parts
            .get(4)
            .map(|value| matches!(value.to_ascii_lowercase().as_str(), "true" | "1" | "yes"))
            .unwrap_or(true);
        let tools = parts
            .get(5)
            .map(|value| matches!(value.to_ascii_lowercase().as_str(), "true" | "1" | "yes"))
            .unwrap_or(true);
        ids.push(id.to_string());
        params.push(ModelPrefs {
            id: id.to_string(),
            context_window: context,
            max_output_tokens: output,
            supports_thinking: thinking,
            enabled,
            supports_tools: tools,
            reasoning_efforts: Vec::new(),
        });
    }
    (ids, params)
}

/// Provider 名称比较用的归一化：去首尾空白 + 小写。
pub fn normalized_provider_name(name: &str) -> String {
    name.trim().to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model_prefs(id: &str) -> ModelPrefs {
        let mut model = ModelPrefs::new(id);
        model.context_window = 128_000;
        model.max_output_tokens = 16_384;
        model.supports_thinking = true;
        model.supports_tools = true;
        model
    }

    #[test]
    fn format_emits_six_columns() {
        let provider = ProviderPrefs {
            models: vec!["deepseek-flash".into()],
            model_params: vec![model_prefs("deepseek-flash")],
            ..ProviderPrefs::default()
        };
        assert_eq!(
            format_model_lines(&provider),
            "deepseek-flash | 128000 | 16384 | true | true | true"
        );
    }

    #[test]
    fn parse_roundtrips_full_format() {
        let (ids, models) = parse_model_lines("m1 | 128000 | 16384 | true | false | false");
        assert_eq!(ids, vec!["m1".to_string()]);
        assert_eq!(models[0].context_window, 128_000);
        assert_eq!(models[0].max_output_tokens, 16_384);
        assert!(models[0].supports_thinking);
        assert!(!models[0].enabled);
        assert!(!models[0].supports_tools);
    }

    #[test]
    fn parse_legacy_five_columns_defaults_tools_true() {
        let (_, models) = parse_model_lines("m1 | 64000 | 8000 | false | true");
        assert!(models[0].supports_tools);
    }

    #[test]
    fn parse_ignores_blank_and_malformed_lines() {
        let (ids, models) = parse_model_lines("\n  \n | 100 | 100\nm1\n");
        assert_eq!(ids, vec!["m1".to_string()]);
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].context_window, 64_000);
        assert_eq!(models[0].max_output_tokens, 8_000);
    }

    #[test]
    fn parse_invalid_numbers_fall_back_to_defaults() {
        let (_, models) = parse_model_lines("m1 | nope | nope");
        assert_eq!(models[0].context_window, 64_000);
        assert_eq!(models[0].max_output_tokens, 8_000);
    }

    #[test]
    fn normalized_name_trims_and_lowercases() {
        assert_eq!(normalized_provider_name("  DeepSeek  "), "deepseek");
        assert_eq!(normalized_provider_name("CGC"), "cgc");
    }
}
