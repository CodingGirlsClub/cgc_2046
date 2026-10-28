use super::*;

impl Agent {
    fn pattern_allows(&self, tool_call: &ToolUse) -> bool {
        let command = tool_call
            .args
            .get("command")
            .and_then(|value| value.as_str());
        let path = tool_call.args.get("path").and_then(|value| value.as_str());
        let serialized = serde_json::to_string(&tool_call.args).unwrap_or_default();
        self.session_patterns.iter().any(|(tool, pattern)| {
            if tool != &tool_call.name {
                return false;
            }
            if let Some(command) = command {
                return command_prefix_match(command.trim(), pattern.trim());
            }
            if let Some(path) = path {
                return prefix_match(path.trim(), pattern);
            }
            serialized == *pattern
        })
    }

    pub(super) async fn execute_tool_call(
        &mut self,
        tool_call: &ToolUse,
        tools: &ToolRegistry,
        context: &ToolContext,
        approver: &dyn Approver,
        observer: &mut dyn TurnObserver,
    ) -> ToolResultSummary {
        let Some(approval) = tools.approval(&tool_call.name, &tool_call.args) else {
            let content = format!("unknown tool: {}", tool_call.name);
            self.thread.push_tool_result(
                tool_call.id.clone(),
                tool_call.name.clone(),
                content.clone(),
                true,
            );
            return ToolResultSummary {
                tool_use_id: tool_call.id.clone(),
                tool_name: tool_call.name.clone(),
                content,
                is_error: true,
            };
        };

        let decision = match approval {
            Approval::Allow => ApprovalDecision::AllowOnce,
            Approval::Deny(reason) => {
                let content = format!("denied by policy: {reason}");
                self.thread.push_tool_result(
                    tool_call.id.clone(),
                    tool_call.name.clone(),
                    content.clone(),
                    true,
                );
                return ToolResultSummary {
                    tool_use_id: tool_call.id.clone(),
                    tool_name: tool_call.name.clone(),
                    content,
                    is_error: true,
                };
            }
            Approval::Ask => {
                let pattern_matches = self.pattern_allows(tool_call);
                if self.session_grants.contains(&tool_call.name) || pattern_matches {
                    ApprovalDecision::AllowOnce
                } else {
                    let request = ApprovalRequest {
                        tool_call_id: tool_call.id.clone(),
                        tool_name: tool_call.name.clone(),
                        args: tool_call.args.clone(),
                    };
                    observer.on_permission_request(&request);
                    approver.decide(request).await
                }
            }
        };

        match decision {
            ApprovalDecision::Deny => {
                let content = "denied by user".to_string();
                self.thread.push_tool_result(
                    tool_call.id.clone(),
                    tool_call.name.clone(),
                    content.clone(),
                    true,
                );
                ToolResultSummary {
                    tool_use_id: tool_call.id.clone(),
                    tool_name: tool_call.name.clone(),
                    content,
                    is_error: true,
                }
            }
            ApprovalDecision::AllowOnce
            | ApprovalDecision::AllowForSession
            | ApprovalDecision::AllowPattern(_) => {
                match &decision {
                    ApprovalDecision::AllowForSession => {
                        self.session_grants.insert(tool_call.name.clone());
                    }
                    ApprovalDecision::AllowPattern(pattern) if !pattern.is_empty() => {
                        self.session_patterns
                            .push((tool_call.name.clone(), pattern.clone()));
                    }
                    _ => {}
                }
                let (content, is_error) = match tools
                    .run(&tool_call.name, tool_call.args.clone(), context.clone())
                    .await
                {
                    Ok(result) => (result.content, result.is_error),
                    Err(error) => (error.to_string(), true),
                };
                self.thread.push_tool_result(
                    tool_call.id.clone(),
                    tool_call.name.clone(),
                    content.clone(),
                    is_error,
                );
                ToolResultSummary {
                    tool_use_id: tool_call.id.clone(),
                    tool_name: tool_call.name.clone(),
                    content,
                    is_error,
                }
            }
        }
    }
}

fn command_prefix_match(command: &str, pattern: &str) -> bool {
    // 仅未引用的简单 argv 可以复用授权；shell 结构、展开、重定向和引号都重新确认。
    // 同时排除 cmd.exe 的 % / ! 展开与 ^ 转义，不能只检查 Unix shell 操作符。
    if pattern.is_empty()
        || !(command == pattern
            || command
                .strip_prefix(pattern)
                .is_some_and(|rest| rest.starts_with([' ', '\t'])))
    {
        return false;
    }
    command.chars().all(|character| {
        character.is_alphanumeric()
            || matches!(
                character,
                ' ' | '\t' | '/' | '.' | '_' | '-' | ':' | '=' | '+' | ',' | '@'
            )
    })
}

fn prefix_match(value: &str, pattern: &str) -> bool {
    if value == pattern {
        return true;
    }
    value
        .strip_prefix(pattern)
        .is_some_and(|rest| rest.starts_with(['/', '\\', ' ', ':', '-']))
}
