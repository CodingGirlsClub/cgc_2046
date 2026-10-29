use std::{collections::BTreeMap, sync::Arc};

use crate::{
    model::{Model, ModelId, ProviderId},
    provider::Provider,
};

/// 已注册 Provider 的集合。UI 的模型选择器只读这里。
#[derive(Default)]
pub struct ProviderRegistry {
    providers: BTreeMap<ProviderId, Arc<dyn Provider>>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, provider: Arc<dyn Provider>) -> Option<Arc<dyn Provider>> {
        self.providers.insert(provider.id().clone(), provider)
    }

    pub fn provider(&self, id: &ProviderId) -> Option<&Arc<dyn Provider>> {
        self.providers.get(id)
    }

    pub fn providers(&self) -> impl Iterator<Item = &Arc<dyn Provider>> {
        self.providers.values()
    }

    /// 全部 provider 的模型，按 provider 排序。
    pub fn models(&self) -> Vec<Model> {
        self.providers
            .values()
            .flat_map(|provider| provider.models())
            .collect()
    }

    pub fn find_model(&self, provider_id: &ProviderId, model_id: &ModelId) -> Option<Model> {
        self.provider(provider_id)?
            .models()
            .into_iter()
            .find(|model| &model.id == model_id)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::{fake::FakeProvider, model::ModelLimits};

    fn model(provider: &str, id: &str) -> Model {
        Model::new(
            ProviderId::new(provider),
            "Test",
            id,
            id,
            ModelLimits::new(8_000, 1_000),
        )
    }

    #[test]
    fn registry_finds_model_and_provider() {
        let mut registry = ProviderRegistry::new();
        let fake = Arc::new(FakeProvider::new(
            ProviderId::new("fake"),
            "Fake",
            vec![model("fake", "a")],
        ));
        registry.register(fake);
        assert_eq!(registry.models().len(), 1);
        let provider_id = ProviderId::new("fake");
        let model_id = ModelId::new("a");
        let found = registry.find_model(&provider_id, &model_id).unwrap();
        assert_eq!(found.id.as_str(), "a");
        assert!(registry.provider(&provider_id).is_some());
        assert!(registry
            .find_model(&provider_id, &ModelId::new("missing"))
            .is_none());
    }
}
