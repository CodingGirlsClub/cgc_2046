//! 获取模型后的合并规则：供应商优先排序，用户已配置的参数不覆盖。
//!
//! 合并只发生在用户点"保存"之前；这里保持纯函数，便于单测。

use std::collections::BTreeSet;

use cgc_agent_provider::{probe::RemoteModel, ThinkingMode};
use cgc_agent_store::ModelPrefs;

/// 缺省值与 `ModelPrefs::default()` 一致：保守的 64K / 8K。
fn from_remote(remote: &RemoteModel) -> ModelPrefs {
    let context_window = remote.context_window.unwrap_or(64_000).max(1);
    let max_output_tokens = remote
        .max_output_tokens
        .unwrap_or(8_000)
        .max(1)
        .min(context_window);
    ModelPrefs {
        id: remote.id.clone(),
        context_window,
        max_output_tokens,
        supports_thinking: !remote.reasoning_efforts.is_empty(),
        enabled: true,
        supports_tools: true,
        supports_images: remote.supports_images.unwrap_or(false),
        reasoning_efforts: remote.reasoning_efforts.clone(),
        thinking_mode: ThinkingMode::Disabled,
    }
}

/// 勾选的远程模型按供应商顺序在前；本地已有同 id 保留原参数；
/// 本地独有的模型追加在末尾（手工添加的模型不会因一次获取而消失）。
pub(crate) fn merge_remote_models(
    remote: &[RemoteModel],
    existing: &[ModelPrefs],
    chosen: &BTreeSet<String>,
) -> (Vec<String>, Vec<ModelPrefs>) {
    let mut models: Vec<String> = Vec::new();
    let mut params: Vec<ModelPrefs> = Vec::new();
    for model in remote {
        if !chosen.contains(&model.id) || models.iter().any(|id| id == &model.id) {
            continue;
        }
        let config = existing
            .iter()
            .find(|config| config.id == model.id)
            .cloned()
            .unwrap_or_else(|| from_remote(model));
        models.push(model.id.clone());
        params.push(config);
    }
    for config in existing {
        if models.iter().any(|id| id == &config.id) {
            continue;
        }
        models.push(config.id.clone());
        params.push(config.clone());
    }
    (models, params)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn remote(id: &str) -> RemoteModel {
        RemoteModel {
            id: id.to_string(),
            name: None,
            context_window: None,
            max_output_tokens: None,
            supports_images: None,
            reasoning_efforts: Vec::new(),
        }
    }

    fn chosen(ids: &[&str]) -> BTreeSet<String> {
        ids.iter().map(|id| id.to_string()).collect()
    }

    #[test]
    fn remote_metadata_fills_a_new_model() {
        let fetched = vec![RemoteModel {
            id: "deepseek-flash".to_string(),
            name: Some("DeepSeek V4.1 Flash".to_string()),
            context_window: Some(1_048_576),
            max_output_tokens: Some(393_216),
            supports_images: Some(true),
            reasoning_efforts: vec!["low".into(), "high".into()],
        }];
        let (models, params) = merge_remote_models(&fetched, &[], &chosen(&["deepseek-flash"]));
        assert_eq!(models, vec!["deepseek-flash"]);
        assert_eq!(params[0].context_window, 1_048_576);
        assert_eq!(params[0].max_output_tokens, 393_216);
        assert!(params[0].supports_images);
        assert!(params[0].supports_thinking);
        assert_eq!(params[0].reasoning_efforts, vec!["low", "high"]);
    }

    #[test]
    fn existing_parameters_survive_a_refetch() {
        let existing = vec![ModelPrefs {
            context_window: 123_456,
            ..ModelPrefs::new("deepseek-flash")
        }];
        let fetched = vec![RemoteModel {
            context_window: Some(1_048_576),
            ..remote("deepseek-flash")
        }];
        let (_, params) = merge_remote_models(&fetched, &existing, &chosen(&["deepseek-flash"]));
        assert_eq!(params[0].context_window, 123_456);
    }

    #[test]
    fn models_missing_from_the_vendor_list_are_kept() {
        let existing = vec![ModelPrefs::new("manual-model")];
        let fetched = vec![remote("deepseek-flash")];
        let (models, params) =
            merge_remote_models(&fetched, &existing, &chosen(&["deepseek-flash"]));
        assert_eq!(models, vec!["deepseek-flash", "manual-model"]);
        assert_eq!(params.len(), 2);
    }

    #[test]
    fn only_chosen_models_are_merged() {
        let fetched = vec![remote("a"), remote("b")];
        let (models, _) = merge_remote_models(&fetched, &[], &chosen(&["b"]));
        assert_eq!(models, vec!["b"]);
    }

    #[test]
    fn a_remote_id_without_metadata_gets_conservative_defaults() {
        let fetched = vec![remote("gpt-x")];
        let (_, params) = merge_remote_models(&fetched, &[], &chosen(&["gpt-x"]));
        assert_eq!(params[0].context_window, 64_000);
        assert_eq!(params[0].max_output_tokens, 8_000);
        assert!(!params[0].supports_thinking);
        assert!(!params[0].supports_images);
        assert!(params[0].supports_tools);
    }
}
