# frozen_string_literal: true

# 用途：发布收口工序的第一步——汇总「距离上次 develop→main 发布，develop 上新增了什么」，
# 供主控/子 agent 据此把 CHANGELOG.md 顶部的 [Unreleased] 段刷新成草稿，再人工润色。
# 用法：ruby scripts/changelog-draft.rb   （在仓库任意 checkout 下运行，需先 git fetch）
#
# 输出五块：
#   1. 发布边界：上一次 develop→main 的 merge（日期 / PR 号）与本次将发布的提交量
#   2. 保留清单：feat/fix/perf/security 等用户可见变更（噪音已过滤，scope 即端标签）
#   3. 门禁提示：本批是否带 migrations / lockfile / 人工合并范围文件，mix.lock 变更时回 deps-image
#   4. 客户端版本文件变更：有则说明本批带客户端/扩展发布，要记独立端节点
#   5. Unreleased 现状：当前 [Unreleased] 段是否为空

require "open3"

NOISE = /\A(?:chore|docs|test|style|ci|build|config|revert|refactor)[(:]/i
KEEP = /\A(?:feat|fix|perf|security|polish)[(:]/i
HUMAN_SCOPE = [
  "backend/priv/repo/migrations/",
  "backend/mix.lock",
  "web/pnpm-lock.yaml",
  "miniprogram/pnpm-lock.yaml",
  ".github/",
  "AGENTS.md",
  "docs/agents/"
].freeze
# 客户端/扩展的版本字段文件——有变更说明本批带客户端发布，要记到独立端节点（[微信 vX]/[扩展 vX]），不算进日期段
VERSION_FILES = %w[
  miniprogram/package.json
  miniprogram/version
  miniprogram/project.config.json
  openclacky-ext/cgc-2046/ext.yml
].freeze

def git(*args)
  out, err, status = Open3.capture3("git", *args)
  raise "git #{args.first} failed: #{err}" unless status.success?

  out
end

last_merge = git("log", "origin/main", "--merges", "--format=%H%x09%ad%x09%s",
                 "--date=format:%Y-%m-%d")
             .lines.map(&:chomp)
             .find { |l| l.include?("from CodingGirlsClub/develop") }
raise "no develop->main merge found on origin/main" unless last_merge

m_hash, m_date, m_subject = last_merge.split("\t", 3)
pr = m_subject[/#(\d+)/, 1]

# 边界用 merge commit 本身（可达集排除），不是 ^1——^1 会漏掉 develop 上已发版的祖先，把旧批次重复计入
commits = git("log", "--no-merges", "--format=%s", "#{m_hash}..origin/develop").lines.map(&:chomp)
kept, noise = commits.partition { |c| c.match?(KEEP) }
raise "unexpected: all commits are noise? (#{commits.size} total)" if commits.any? && kept.empty? &&
  noise.all? { |c| c.match?(NOISE) } == false

changed = git("diff", "--name-only", "#{m_hash}..origin/develop").lines.map(&:chomp)
human_hit = changed.select { |f| HUMAN_SCOPE.any? { |s| f.start_with?(s) } }
mix_lock_changed = changed.include?("backend/mix.lock")
version_hit = changed & VERSION_FILES

cl = git("show", "origin/develop:CHANGELOG.md") rescue ""
unreleased = cl[/^## \[Unreleased\]\n(.*?)(?=^## )/m, 1].to_s.strip

puts "# 发布边界"
puts "上次发布：#{m_date} merge #{m_hash[0, 8]}（PR ##{pr}）"
puts "本批非 merge 提交：#{commits.size} 条（保留 #{kept.size} / 噪音 #{noise.size}）"
puts
puts "# 保留清单（据此写 [Unreleased] 草稿，同类浓缩、每条≤一行；scope 即端标签，写条目时保留 [微信]/[扩展] 等前缀）"
kept.each { |c| puts "- #{c}" }
puts
puts "# 门禁提示"
puts "mix.lock 变更：#{mix_lock_changed ? "是——先确认 develop CI 的 deps-image job 已绿再合 main" : "否"}"
puts "人工合并范围文件：#{human_hit.empty? ? "无" : human_hit.uniq.join(", ")}"
puts "客户端版本文件变更：#{version_hit.empty? ? "无" : version_hit.join(", ") + "——本批带客户端/扩展版本变化，记到独立端节点，别算进日期段"}"
puts "[Unreleased] 段当前：#{unreleased.empty? ? "空——需要生成草稿" : "非空（#{unreleased.lines.count { |l| l.start_with?('- ') }} 条）"}"
