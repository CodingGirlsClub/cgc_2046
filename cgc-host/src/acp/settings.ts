// settings.ts — 会话设置（#1145）：把 agent 的 ACP config options 收窄成页面可改的两类（模型、思考/推理强度）。
import type { SessionConfigOption } from "@agentclientprotocol/sdk";

/**
 * 页面可改的会话设置（agent 的 configId）：模型与思考/推理强度——OMP 叫 thinking，Codex 叫 reasoning_effort；
 * mode（plan）是 agent 执行策略，不透出。按 id 收窄而不是按 category：两个 agent 的 id 不同名。
 */
export const SETTING_IDS: Record<string, true> = { model: true, thinking: true, reasoning_effort: true };
/** 单个设置项的取值上限：值是 provider/model 这类短标识 */
export const SETTING_VALUE_MAX = 256;

/**
 * 透给页面的会话设置项：ACP 的 configOptions 收窄成只剩模型与思考/推理强度，分组形状摊平成一层
 * （页面自己按 provider 前缀分组显示），值只取 string。
 */
export interface ConfigOption {
  id: string;
  name: string;
  category: string;
  currentValue: string;
  options: { value: string; name: string; description?: string }[];
}

/** agent 没给 configOptions（旧版本）或项目的形状不合约时返回空数组：页面据此不渲染设置控件 */
export function pickSettings(configOptions: readonly SessionConfigOption[] | null | undefined): ConfigOption[] {
  const picked: ConfigOption[] = [];
  for (const option of configOptions ?? []) {
    if (option.type !== "select" || !Object.hasOwn(SETTING_IDS, option.id)) continue;
    const items = option.options.flatMap((item) => ("group" in item ? item.options : [item]));
    picked.push({
      id: option.id,
      name: option.name,
      category: option.category ?? option.id,
      currentValue: option.currentValue,
      options: items.map(({ value, name, description }) => ({ value, name, ...(description ? { description } : {}) })),
    });
  }
  return picked;
}
