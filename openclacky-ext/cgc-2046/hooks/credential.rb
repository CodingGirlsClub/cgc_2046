# frozen_string_literal: true

# CGC-2046 hook 共享的凭证脱敏正则。
#
# 覆盖三种形态（统一替换为 <redacted>）：
#   1. Bearer <token> —— token 字符集含 base64 的 +/=，防止尾部泄漏；
#   2. cgc_<token> —— 平台连接 token 前缀（LLM 散文转述形态，无 "Bearer " 前缀）；
#   3. 裸 JWT（三段 base64url，每段 ≥20 字符）。
#
# 两个 hook 文件 require_relative 本文件（require 幂等），无加载顺序依赖。

module Cgc2046HookCredential
  PATTERN =
    /(?:Bearer\s+)[A-Za-z0-9._\-+\/=]+|cgc_[A-Za-z0-9._\-]{8,}|[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]+/
end
