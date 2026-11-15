//! 获取模型后的合并规则：供应商优先排序，用户已配置的参数不覆盖。
//!
//! 合并只发生在用户点"保存"之前；这里保持纯函数，便于单测。

use std::collections::BTreeSet;

use cgc_agent_provider::probe::RemoteModel;
use cgc_agent_store::ModelPrefs;

/// 目录里已有的同 id 模型（内置目录），用它补齐供应商没说明的字段。
fn from_catalog(remote: &RemoteModel, catalog: &[ModelPrefs]) -> Option<ModelPrefs> {
    catalog.iter().find(|known| known.id == remote.id).cloned()
}

/// 供应商给的字段优先，缺的用目录补，再缺用保守默认。
fn from_remote(remote: &RemoteModel, catalog: &[ModelPrefs]) -> ModelPrefs {
    let known = from_catalog(remote, catalog).unwrap_or_else(|| ModelPrefs::new(&remote.id));
    let context_window = remote.context_window.unwrap_or(known.context_window).max(1);
    let max_output_tokens = remote
        .max_output_tokens
        .unwrap_or(known.max_output_tokens)
        .max(1)
        .min(context_window);
    ModelPrefs {
        id: remote.id.clone(),
        context_window,
        max_output_tokens,
        supports_thinking: if remote.reasoning_efforts.is_empty() {
            known.supports_thinking
        } else {
            true
        },
        enabled: true,
        supports_tools: known.supports_tools,
        supports_images: remote.supports_images.unwrap_or(known.supports_images),
        reasoning_efforts: if remote.reasoning_efforts.is_empty() {
            known.reasoning_efforts
        } else {
            remote.reasoning_efforts.clone()
        },
        thinking_mode: known.thinking_mode,
    }
}

/// 勾选的远程模型按供应商顺序在前；本地已有同 id 保留原参数；
/// 本地独有的模型追加在末尾（手工添加的模型不会因一次获取而消失）。
/// 新模型优先用供应商给的元数据，缺的字段由目录补齐，再缺用保守默认。
pub(crate) fn merge_remote_models(
    remote: &[RemoteModel],
    existing: &[ModelPrefs],
    chosen: &BTreeSet<String>,
    catalog: &[ModelPrefs],
) -> (Vec<String>, Vec<ModelPrefs>) {
    let mut models: Vec<String> = Vec::new();
    let mut params: Vec<ModelPrefs> = Vec::new();
    for model in remote {
        if !chosen.contains(&model.id) || models.iter().any(|id| id == &model.id) {
            continue;
        }
        let config = match existing.iter().find(|config| config.id == model.id) {
            Some(local) => {
                let mut local = local.clone();
                // 本地没声明档位时用供应商的补上；已有声明保持用户的选择。
                if local.reasoning_efforts.is_empty() && !model.reasoning_efforts.is_empty() {
                    local.reasoning_efforts = model.reasoning_efforts.clone();
                    local.supports_thinking = true;
                }
                local
            }
            None => from_remote(model, catalog),
        };
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

/// 保存时用最近一次获取结果补空档位：只补已有模型，不新增、不覆盖声明。
pub(crate) fn fill_missing_efforts(
    local: &[ModelPrefs],
    remote: &[RemoteModel],
) -> Vec<ModelPrefs> {
    local
        .iter()
        .map(|model| {
            if model.reasoning_efforts.is_empty() {
                if let Some(found) = remote
                    .iter()
                    .find(|entry| entry.id == model.id && !entry.reasoning_efforts.is_empty())
                {
                    let mut filled = model.clone();
                    filled.reasoning_efforts = found.reasoning_efforts.clone();
                    filled.supports_thinking = true;
                    return filled;
                }
            }
            model.clone()
        })
        .collect()
}

/// 当前 unix 秒，用于记录供应商目录的获取时间。
pub(crate) fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
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
        let (models, params) =
            merge_remote_models(&fetched, &[], &chosen(&["deepseek-flash"]), &[]);
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
        let (_, params) =
            merge_remote_models(&fetched, &existing, &chosen(&["deepseek-flash"]), &[]);
        assert_eq!(params[0].context_window, 123_456);
    }

    #[test]
    fn saving_fills_empty_efforts_from_the_last_fetch() {
        let local = vec![ModelPrefs::new("auto/x")];
        let remote = vec![RemoteModel {
            reasoning_efforts: vec!["low".into(), "high".into()],
            ..remote("auto/x")
        }];
        let filled = fill_missing_efforts(&local, &remote);
        assert_eq!(filled.len(), 1);
        assert_eq!(filled[0].reasoning_efforts, vec!["low", "high"]);
        assert!(filled[0].supports_thinking);
    }

    #[test]
    fn saving_keeps_declared_efforts() {
        let local = vec![ModelPrefs {
            reasoning_efforts: vec!["max".into()],
            ..ModelPrefs::new("auto/x")
        }];
        let remote = vec![RemoteModel {
            reasoning_efforts: vec!["low".into()],
            ..remote("auto/x")
        }];
        let filled = fill_missing_efforts(&local, &remote);
        assert_eq!(filled[0].reasoning_efforts, vec!["max"]);
    }

    #[test]
    fn models_missing_from_the_vendor_list_are_kept() {
        let existing = vec![ModelPrefs::new("manual-model")];
        let fetched = vec![remote("deepseek-flash")];
        let (models, params) =
            merge_remote_models(&fetched, &existing, &chosen(&["deepseek-flash"]), &[]);
        assert_eq!(models, vec!["deepseek-flash", "manual-model"]);
        assert_eq!(params.len(), 2);
    }

    #[test]
    fn only_chosen_models_are_merged() {
        let fetched = vec![remote("a"), remote("b")];
        let (models, _) = merge_remote_models(&fetched, &[], &chosen(&["b"]), &[]);
        assert_eq!(models, vec!["b"]);
    }

    #[test]
    fn a_remote_id_without_metadata_gets_conservative_defaults() {
        let fetched = vec![remote("gpt-x")];
        let (_, params) = merge_remote_models(&fetched, &[], &chosen(&["gpt-x"]), &[]);
        assert_eq!(params[0].context_window, 64_000);
        assert_eq!(params[0].max_output_tokens, 8_000);
        assert!(!params[0].supports_thinking);
        assert!(!params[0].supports_images);
        assert!(params[0].supports_tools);
    }

    #[test]
    fn catalog_fills_metadata_the_vendor_omits() {
        let catalog = vec![ModelPrefs {
            context_window: 1_000_000,
            max_output_tokens: 384_000,
            ..ModelPrefs::new("deepseek-flash")
        }];
        let fetched = vec![remote("deepseek-flash")];
        let (_, params) =
            merge_remote_models(&fetched, &[], &chosen(&["deepseek-flash"]), &catalog);
        assert_eq!(params[0].context_window, 1_000_000);
        assert_eq!(params[0].max_output_tokens, 384_000);
        assert!(params[0].enabled, "catalog entries join enabled");
    }

    #[test]
    fn a_local_config_still_wins_over_the_catalog() {
        let catalog = vec![ModelPrefs {
            context_window: 1_000_000,
            ..ModelPrefs::new("deepseek-flash")
        }];
        let existing = vec![ModelPrefs {
            context_window: 8_192,
            ..ModelPrefs::new("deepseek-flash")
        }];
        let fetched = vec![remote("deepseek-flash")];
        let (_, params) =
            merge_remote_models(&fetched, &existing, &chosen(&["deepseek-flash"]), &catalog);
        assert_eq!(params[0].context_window, 8_192);
    }

    #[test]
    fn refetch_fills_missing_effort_levels() {
        let existing = vec![ModelPrefs::new("m")];
        let fetched = vec![RemoteModel {
            reasoning_efforts: vec!["low".into(), "high".into()],
            ..remote("m")
        }];
        let (_, params) = merge_remote_models(&fetched, &existing, &chosen(&["m"]), &[]);
        assert_eq!(params[0].reasoning_efforts, vec!["low", "high"]);
        assert!(params[0].supports_thinking);
    }

    #[test]
    fn refetch_keeps_explicit_effort_levels() {
        let existing = vec![ModelPrefs {
            reasoning_efforts: vec!["max".into()],
            ..ModelPrefs::new("m")
        }];
        let fetched = vec![RemoteModel {
            reasoning_efforts: vec!["low".into(), "high".into()],
            ..remote("m")
        }];
        let (_, params) = merge_remote_models(&fetched, &existing, &chosen(&["m"]), &[]);
        assert_eq!(params[0].reasoning_efforts, vec!["max"]);
    }

    #[test]
    fn vendor_metadata_wins_over_the_catalog() {
        let catalog = vec![ModelPrefs {
            context_window: 8_192,
            ..ModelPrefs::new("m")
        }];
        let fetched = vec![RemoteModel {
            context_window: Some(999_999),
            ..remote("m")
        }];
        let (_, params) = merge_remote_models(&fetched, &[], &chosen(&["m"]), &catalog);
        assert_eq!(
            params[0].context_window, 999_999,
            "the vendor's own figure beats the catalog"
        );
    }
}
