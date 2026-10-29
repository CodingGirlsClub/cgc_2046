/// 一条 SSE 事件。`data` 已按 SSE 规则把多行用 `\n` 连接。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SseEvent {
    pub event: Option<String>,
    pub data: String,
}

/// 增量 SSE 解码器：接受任意切分的字节块，输出完整事件。
#[derive(Default, Debug)]
pub struct SseDecoder {
    buffer: String,
    data: String,
    event: Option<String>,
}

impl SseDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    /// 喂入一个文本块（UTF-8），返回其中已经完整的事件。
    pub fn feed(&mut self, chunk: &str) -> Vec<SseEvent> {
        self.buffer.push_str(chunk);
        let mut events = Vec::new();
        while let Some(position) = self.buffer.find('\n') {
            let line: String = self.buffer.drain(..=position).collect();
            if let Some(event) = self.process_line(line.trim_end_matches(['\n', '\r'])) {
                events.push(event);
            }
        }
        events
    }

    /// 流结束时把残留事件吐出（服务端未发空行就断开的情况）。
    pub fn finish(&mut self) -> Option<SseEvent> {
        let trailing = std::mem::take(&mut self.buffer);
        if !trailing.is_empty() {
            let _ = self.process_line(trailing.trim_end_matches(['\n', '\r']));
        }
        self.take_event()
    }

    /// 处理一行；返回被空行触发的完整事件。
    fn process_line(&mut self, line: &str) -> Option<SseEvent> {
        if line.is_empty() {
            return self.take_event();
        }
        if line.starts_with(':') {
            return None;
        }
        let (field, value) = match line.find(':') {
            Some(index) => (&line[..index], &line[index + 1..]),
            None => (line, ""),
        };
        let value = value.strip_prefix(' ').unwrap_or(value);
        match field {
            "data" => {
                if !self.data.is_empty() {
                    self.data.push('\n');
                }
                self.data.push_str(value);
            }
            "event" => self.event = Some(value.to_string()),
            _ => {}
        }
        None
    }

    fn take_event(&mut self) -> Option<SseEvent> {
        if self.data.is_empty() && self.event.is_none() {
            return None;
        }
        Some(SseEvent {
            event: self.event.take(),
            data: std::mem::take(&mut self.data),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_events_split_across_chunks() {
        let mut decoder = SseDecoder::new();
        assert!(decoder.feed("data: {\"a\":").is_empty());
        let events = decoder.feed("1}\n\n");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "{\"a\":1}");
    }

    #[test]
    fn joins_multi_line_data_and_ignores_comments() {
        let mut decoder = SseDecoder::new();
        let events = decoder.feed(": ping\nevent: delta\ndata: line1\ndata: line2\n\n");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event.as_deref(), Some("delta"));
        assert_eq!(events[0].data, "line1\nline2");
    }

    #[test]
    fn handles_crlf_and_done() {
        let mut decoder = SseDecoder::new();
        let events = decoder.feed("data: [DONE]\r\n\r\n");
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "[DONE]");
    }

    #[test]
    fn finish_flushes_trailing_event_without_blank_line() {
        let mut decoder = SseDecoder::new();
        let events = decoder.feed("data: tail");
        assert!(events.is_empty());
        let flushed = decoder.finish().expect("flushed");
        assert_eq!(flushed.data, "tail");
    }
}
