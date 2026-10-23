//! P0 T3 的可交互 demo：把 provider → core → tools 串起来。
//!
//! 真实 provider（环境变量）：
//!   CGC_AGENT_BASE_URL=https://api.deepseek.com/v1 \
//!   CGC_AGENT_API_KEY=sk-... CGC_AGENT_MODEL=deepseek-chat \
//!   cgc-agent-demo --workspace /path/to/workspace --allow-tools
//!
//! 无人值守自检（不联网）：
//!   cgc-agent-demo --selftest

use std::io::{BufRead, Write};
use std::path::PathBuf;

use cgc_agent_core::{
    Agent, AgentError, ApprovalRequest, AutoApprover, SelectedModel, Thread, ToolResultSummary,
    ToolTurnOutcome, TurnObserver,
};
use cgc_agent_provider::TokenUsage;
use cgc_agent_provider::{
    CompletionEvent, FakeProvider, Model, ModelId, ModelLimits, OpenAiCompatibleConfig,
    OpenAiCompatibleProvider, ProviderId, StopReason, ToolUse,
};
use cgc_agent_tools::{AgentState, SandboxPolicy, SharedAgentState, ToolContext, ToolRegistry};

/// CLI 的流式打印：文本直接输出，工具调用走 stderr，避免污染答案。
struct PrintObserver;

impl TurnObserver for PrintObserver {
    fn on_text(&mut self, delta: &str) {
        print!("{delta}");
        let _ = std::io::stdout().flush();
    }

    fn on_tool_call(&mut self, tool_use: &cgc_agent_provider::ToolUse) {
        eprintln!("[tool] {} {}", tool_use.name, tool_use.args);
    }

    fn on_permission_request(&mut self, request: &ApprovalRequest) {
        eprintln!("[approval requested] {}", request.tool_name);
    }

    fn on_tool_result(&mut self, summary: &ToolResultSummary) {
        eprintln!(
            "[tool result] {} · {}",
            summary.tool_name,
            if summary.is_error { "失败" } else { "完成" }
        );
    }

    fn on_usage(&mut self, usage: TokenUsage, total: TokenUsage) {
        eprintln!(
            "[usage] 本轮 {} · 累计 {}",
            usage.input + usage.output,
            total.input + total.output
        );
    }

    fn on_finished(&mut self, _outcome: &ToolTurnOutcome) {
        println!();
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Mode {
    SelfTest,
    Repl,
}

#[derive(Debug, PartialEq, Eq)]
struct Options {
    mode: Mode,
    workspace: PathBuf,
    allow_tools: bool,
    once: Option<String>,
}

fn parse_args(args: impl IntoIterator<Item = String>) -> Result<Options, String> {
    let mut mode = Mode::Repl;
    let mut workspace = PathBuf::from(".");
    let mut allow_tools = false;
    let mut once = None;
    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--selftest" => mode = Mode::SelfTest,
            "--allow-tools" => allow_tools = true,
            "--once" => {
                once = Some(
                    iter.next()
                        .ok_or_else(|| "--once requires a prompt".to_string())?,
                );
            }
            "--workspace" => {
                workspace = iter
                    .next()
                    .ok_or_else(|| "--workspace requires a path".to_string())?
                    .into();
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(Options {
        mode,
        workspace,
        allow_tools,
        once,
    })
}

fn main() -> std::process::ExitCode {
    let options = match parse_args(std::env::args().skip(1)) {
        Ok(options) => options,
        Err(error) => {
            eprintln!("{error}");
            return std::process::ExitCode::FAILURE;
        }
    };
    match options.mode {
        Mode::SelfTest => run_selftest(),
        Mode::Repl => run_repl(options),
    }
}

fn run_selftest() -> std::process::ExitCode {
    let workspace =
        std::env::temp_dir().join(format!("cgc-agent-demo-selftest-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&workspace);
    if let Err(error) = std::fs::create_dir_all(&workspace) {
        eprintln!("SELFTEST FAILED: {error}");
        return std::process::ExitCode::FAILURE;
    }
    if let Err(error) = std::fs::write(workspace.join("a.txt"), "hello") {
        eprintln!("SELFTEST FAILED: {error}");
        return std::process::ExitCode::FAILURE;
    }

    let model = Model::new(
        ProviderId::new("fake"),
        "Fake",
        "m1",
        "m1",
        ModelLimits::new(8_000, 1_000),
    );
    let fake = FakeProvider::new(ProviderId::new("fake"), "Fake", vec![model.clone()]);
    fake.push_script(vec![
        Ok(CompletionEvent::ToolUse(ToolUse {
            id: "call_1".into(),
            name: "read_file".into(),
            args: serde_json::json!({"path": "a.txt"}),
        })),
        Ok(CompletionEvent::Stop(StopReason::ToolUse)),
    ]);
    fake.push_script(vec![
        Ok(CompletionEvent::Text("SELFTEST OK".into())),
        Ok(CompletionEvent::Stop(StopReason::EndTurn)),
    ]);

    let thread = Thread::new(
        "selftest",
        SelectedModel::new(ProviderId::new("fake"), ModelId::new("m1")),
    );
    let mut agent = Agent::new(thread, Some("selftest agent".to_string()));
    let registry = ToolRegistry::with_read_tools();
    let context = ToolContext::new(&workspace).with_sandbox(SandboxPolicy::new(&workspace));
    let outcome = futures::executor::block_on(agent.prompt_with_tools(
        &fake,
        &model,
        "read a.txt",
        &registry,
        &context,
        &AutoApprover,
    ));
    let _ = std::fs::remove_dir_all(&workspace);

    match outcome {
        Ok(outcome)
            if outcome.text.contains("SELFTEST OK")
                && outcome.tool_results.len() == 1
                && !outcome.tool_results[0].is_error =>
        {
            println!("SELFTEST OK");
            std::process::ExitCode::SUCCESS
        }
        Ok(outcome) => {
            eprintln!("SELFTEST FAILED: unexpected outcome {outcome:?}");
            std::process::ExitCode::FAILURE
        }
        Err(error) => {
            eprintln!("SELFTEST FAILED: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

fn run_repl(options: Options) -> std::process::ExitCode {
    let base_url = std::env::var("CGC_AGENT_BASE_URL").unwrap_or_default();
    let api_key = std::env::var("CGC_AGENT_API_KEY").unwrap_or_default();
    let model_id = std::env::var("CGC_AGENT_MODEL").unwrap_or_default();
    if base_url.is_empty() || api_key.is_empty() || model_id.is_empty() {
        eprintln!(
            "缺少环境变量：CGC_AGENT_BASE_URL / CGC_AGENT_API_KEY / CGC_AGENT_MODEL（或使用 --selftest）"
        );
        return std::process::ExitCode::FAILURE;
    }

    let provider_name = std::env::var("CGC_AGENT_PROVIDER_NAME")
        .unwrap_or_else(|_| "OpenAI Compatible".to_string());
    let model = Model::new(
        ProviderId::new("custom"),
        provider_name,
        model_id.clone(),
        model_id,
        ModelLimits::new(64_000, 8_000),
    );
    let provider = OpenAiCompatibleProvider::new(OpenAiCompatibleConfig::new(
        base_url,
        api_key,
        vec![model.clone()],
    ));
    let thread = Thread::new(
        "demo",
        SelectedModel::new(model.provider_id.clone(), model.id.clone()),
    );
    let system_prompt = std::env::var("CGC_AGENT_SYSTEM_PROMPT").ok();
    let mut agent = Agent::new(thread, system_prompt);
    let workspace = options.workspace;
    let agent_state: SharedAgentState =
        std::sync::Arc::new(std::sync::Mutex::new(AgentState::default()));
    let registry = ToolRegistry::with_agent_state(agent_state.clone());
    let context = ToolContext::new(&workspace).with_sandbox(SandboxPolicy::new(&workspace));

    println!("CGC native agent demo");
    println!("workspace: {}", workspace.display());
    println!("model: {}/{}", model.provider_id, model.id);
    println!(
        "tools: {}",
        if options.allow_tools {
            "on"
        } else {
            "off（加 --allow-tools 开启）"
        }
    );
    if let Some(prompt) = options.once {
        let result = if options.allow_tools {
            let mut observer = PrintObserver;
            futures::executor::block_on(agent.prompt_with_tools_observed(
                &provider,
                &model,
                prompt,
                &registry,
                &context,
                &AutoApprover,
                &mut observer,
            ))
            .map(|outcome| outcome.text)
        } else {
            futures::executor::block_on(agent.prompt(&provider, &model, prompt))
                .map(|outcome| outcome.text)
        };
        return match result {
            Ok(text) => {
                println!("{text}");
                std::process::ExitCode::SUCCESS
            }
            Err(error) => {
                eprintln!("error: {error}");
                std::process::ExitCode::FAILURE
            }
        };
    }

    println!("输入问题；/tools 查看工具，/quit 退出");

    let stdin = std::io::stdin();
    loop {
        print!("> ");
        let _ = std::io::stdout().flush();
        let mut line = String::new();
        if stdin.lock().read_line(&mut line).unwrap_or(0) == 0 {
            break;
        }
        let input = line.trim();
        if input.is_empty() {
            continue;
        }
        match input {
            "/quit" | "/exit" => break,
            "/tools" => {
                for schema in registry.schemas() {
                    println!("- {}: {}", schema.name, schema.description);
                }
                continue;
            }
            _ => {}
        }

        let result = if options.allow_tools {
            let mut observer = PrintObserver;
            futures::executor::block_on(agent.prompt_with_tools_observed(
                &provider,
                &model,
                input,
                &registry,
                &context,
                &AutoApprover,
                &mut observer,
            ))
            .map(|outcome| outcome.text)
        } else {
            futures::executor::block_on(agent.prompt(&provider, &model, input))
                .map(|outcome| outcome.text)
        };

        match result {
            Ok(_text) => {
                if let Ok(state) = agent_state.lock() {
                    if let Some(summary) = state.summary() {
                        eprintln!("[{summary}]");
                    }
                }
            }
            Err(AgentError::Provider(error)) => eprintln!("provider error: {error}"),
            Err(error) => eprintln!("error: {error}"),
        }
    }
    std::process::ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_selftest_mode() {
        let options = parse_args(["--selftest".to_string()]).expect("parse");
        assert_eq!(options.mode, Mode::SelfTest);
        assert!(!options.allow_tools);
        assert!(options.once.is_none());
    }

    #[test]
    fn parses_workspace_and_tools() {
        let options = parse_args([
            "--workspace".to_string(),
            "/tmp/ws".to_string(),
            "--allow-tools".to_string(),
        ])
        .expect("parse");
        assert_eq!(options.workspace, PathBuf::from("/tmp/ws"));
        assert!(options.allow_tools);
        assert!(options.once.is_none());
    }

    #[test]
    fn parses_once_prompt() {
        let options = parse_args(["--once".to_string(), "hello".to_string()]).expect("parse");
        assert_eq!(options.once.as_deref(), Some("hello"));
    }

    #[test]
    fn rejects_unknown_argument() {
        assert!(parse_args(["--nope".to_string()]).is_err());
    }
}
