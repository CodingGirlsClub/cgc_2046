# frozen_string_literal: true

# 用途：发布收口工序的第一步——汇总「距离上次 develop→main 发布，develop 上新增了什么」，
# 供主控/子 agent 据此把 CHANGELOG.md 顶部的 [Unreleased] 段刷新成草稿，再人工润色。
# 用法：ruby scripts/changelog-draft.rb   （在仓库任意 checkout 下运行，需先 git fetch --tags）
#
# 输出三节：
#   1. 发布边界：上一次 develop→main 的 merge（日期 / PR 号）与本次将发布的提交量
#   2. 保留清单：feat/fix/perf/security/polish 等用户可见变更（原样输出 subject，由收口工序按 scope 标前缀）
#   3. 门禁提示：
#      - deps-image 4 项编译输入变更（mix.lock / Dockerfile.deps / config.exs / prod.exs）
#      - 人工合并范围文件（含 desktop/Cargo.lock）
#      - 客户端版本文件变更（miniprogram/package.json / openclacky-ext/cgc-2046/ext.yml / desktop/Cargo.toml）
#      - 客户端/扩展目录变更（desktop/ / miniprogram/ / openclacky-ext/）与区间内 desktop-v* tag
#      - Server 面（backend/ / web/）是否有变更，以及 [Unreleased] 段现状

require "open3"

module ChangelogDraft
  NOISE = /\A(?:chore|docs|test|style|ci|build|config|revert|refactor)[(:]/i
  KEEP = /\A(?:feat|fix|perf|security|polish)[(:]/i

  HUMAN_SCOPE = [
    "backend/priv/repo/migrations/",
    "backend/mix.lock",
    "web/pnpm-lock.yaml",
    "miniprogram/pnpm-lock.yaml",
    "desktop/Cargo.lock",
    ".github/",
    "AGENTS.md",
    "docs/agents/"
  ].freeze

  # 预编译 deps 镜像的全部输入（与根 AGENTS.md「Deploy deps 镜像节奏」同源）
  DEPS_IMAGE_FILES = %w[
    backend/mix.lock
    backend/Dockerfile.deps
    backend/config/config.exs
    backend/config/prod.exs
  ].freeze

  # 仓内实际承载应用版本号的客户端/扩展文件（小红书/抖音版本在开放平台独立维护，不写进仓内 JSON）
  VERSION_FILES = %w[
    miniprogram/package.json
    openclacky-ext/cgc-2046/ext.yml
    desktop/Cargo.toml
  ].freeze

  CLIENT_DIR_LABELS = {
    "desktop/" => "Desktop",
    "miniprogram/" => "小程序（微信/小红书/抖音）",
    "openclacky-ext/" => "扩展"
  }.freeze

  SERVER_DIRS = %w[backend/ web/].freeze

  module_function

  def git(*args, chdir: nil)
    cmd = chdir ? ["git", "-C", chdir, *args] : ["git", *args]
    out, err, status = Open3.capture3(*cmd)
    raise "git #{args.first} failed: #{err}" unless status.success?

    out
  end

  def classify_commits(commits)
    kept, noise = commits.partition { |c| c.match?(KEEP) }
    if commits.any? && kept.empty? && noise.all? { |c| c.match?(NOISE) } == false
      raise "unexpected: all commits are noise? (#{commits.size} total)"
    end

    { kept: kept, noise: noise }
  end

  def analyze_changes(changed, desktop_tags: [])
    human_hit = changed.select { |f| HUMAN_SCOPE.any? { |s| f.start_with?(s) } }.uniq
    deps_image_hit = changed & DEPS_IMAGE_FILES
    version_hit = changed & VERSION_FILES
    client_dirs = CLIENT_DIR_LABELS.each_with_object([]) do |(prefix, label), acc|
      acc << "#{prefix}（#{label}）" if changed.any? { |f| f.start_with?(prefix) }
    end
    server_changed = changed.any? { |f| SERVER_DIRS.any? { |dir| f.start_with?(dir) } }

    {
      human_hit: human_hit,
      deps_image_hit: deps_image_hit,
      version_hit: version_hit,
      client_dirs: client_dirs,
      server_changed: server_changed,
      desktop_tags: Array(desktop_tags)
    }
  end

  def extract_unreleased(changelog_text)
    changelog_text[/^## \[Unreleased\]\r?\n(.*?)(?=^## |\z)/m, 1].to_s.strip
  end

  def format_report(last_merge:, commits_summary:, analysis:, unreleased:)
    lines = []
    pr_label = last_merge[:pr] ? "（PR ##{last_merge[:pr]}）" : ""
    kept = commits_summary[:kept]

    lines << "# 发布边界"
    lines << "上次发布：#{last_merge[:date]} merge #{last_merge[:hash]}#{pr_label}"
    lines << "本批非 merge 提交：#{commits_summary[:total]} 条（保留 #{kept.size} / 噪音 #{commits_summary[:noise_count]}）"
    lines << ""
    lines << "# 保留清单（据此写 [Unreleased] 草稿，同类浓缩、每条≤一行；scope 即端标签，写条目时保留 [微信]/[小红书]/[扩展]/[Desktop] 等前缀）"
    kept.each { |c| lines << "- #{c}" }
    lines << ""
    lines << "# 门禁提示"

    deps_hit = analysis[:deps_image_hit]
    lines << if deps_hit.empty?
               "deps-image 编译输入变更：无"
             else
               "deps-image 编译输入变更：#{deps_hit.join(", ")}——先确认 develop CI 的 deps-image job 已绿再合 main"
             end

    human_hit = analysis[:human_hit]
    lines << "人工合并范围文件：#{human_hit.empty? ? "无" : human_hit.join(", ")}"

    version_hit = analysis[:version_hit]
    lines << if version_hit.empty?
               "客户端版本文件变更：无"
             else
               "客户端版本文件变更：#{version_hit.join(", ")}——本批带客户端/扩展版本变化，记到独立端节点，别算进日期段"
             end

    client_dirs = analysis[:client_dirs]
    lines << if client_dirs.empty?
               "客户端/扩展目录变更：无"
             else
               "客户端/扩展目录变更：#{client_dirs.join(", ")}——若含客户端发布内容，请落独立端节点，勿误算进 server 日期段"
             end

    desktop_tags = analysis[:desktop_tags]
    lines << if desktop_tags.empty?
               "区间内 Desktop tag：无"
             else
               "区间内 Desktop tag：#{desktop_tags.join(", ")}——核对是否已记入 CHANGELOG 的 [Desktop vX] 节点"
             end

    server_changed = analysis[:server_changed]
    lines << "Server 面（backend/web）变更：#{server_changed ? "有" : "无"}"
    lines << "[Unreleased] 段当前：#{unreleased_status(unreleased, server_changed)}"

    "#{lines.join("\n")}\n"
  end

  def unreleased_status(unreleased, server_changed)
    if unreleased.empty?
      server_changed ? "空——需要生成草稿" : "空——本批无 server 面变更，无需为日期段生成草稿"
    else
      count = unreleased.lines.count { |l| l.start_with?("- ") }
      "非空（#{count} 条）"
    end
  end

  def run(chdir: nil)
    last_merge = git(
      "log", "origin/main", "--merges", "--format=%H%x09%ad%x09%s", "--date=format:%Y-%m-%d",
      chdir: chdir
    ).lines.map(&:chomp).find { |l| l.include?("from CodingGirlsClub/develop") }
    raise "no develop->main merge found on origin/main" unless last_merge

    m_hash, m_date, m_subject = last_merge.split("\t", 3)
    pr = m_subject[/#(\d+)/, 1]

    # 边界用 merge commit 本身（可达集排除），不是 ^1——^1 会漏掉 develop 上已发版的祖先，把旧批次重复计入
    commits = git("log", "--no-merges", "--format=%s", "#{m_hash}..origin/develop", chdir: chdir)
              .lines.map(&:chomp)
    classified = classify_commits(commits)

    changed = git("diff", "--name-only", "#{m_hash}..origin/develop", chdir: chdir).lines.map(&:chomp)
    desktop_tags = git(
      "tag", "--merged", "origin/develop", "--no-merged", m_hash,
      "-l", "desktop-v*", "--sort=creatordate", chdir: chdir
    ).lines.map(&:chomp).reject(&:empty?)

    analysis = analyze_changes(changed, desktop_tags: desktop_tags)

    changelog_text = begin
      git("show", "origin/develop:CHANGELOG.md", chdir: chdir)
    rescue StandardError
      ""
    end
    unreleased = extract_unreleased(changelog_text)

    print format_report(
      last_merge: { date: m_date, hash: m_hash[0, 8], pr: pr },
      commits_summary: {
        total: commits.size,
        kept: classified[:kept],
        noise_count: classified[:noise].size
      },
      analysis: analysis,
      unreleased: unreleased
    )
  end
end

ChangelogDraft.run if File.expand_path($PROGRAM_NAME) == File.expand_path(__FILE__)
