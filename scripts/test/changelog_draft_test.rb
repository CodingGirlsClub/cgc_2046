require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

require_relative "../changelog-draft"

class ChangelogDraftTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.expand_path("../changelog-draft.rb", __dir__)

  def test_tracked_paths_exist_in_repo
    ChangelogDraft::VERSION_FILES.each do |path|
      assert File.file?(File.join(ROOT, path)), "VERSION_FILES missing in repo: #{path}"
    end

    ChangelogDraft::DEPS_IMAGE_FILES.each do |path|
      assert File.file?(File.join(ROOT, path)), "DEPS_IMAGE_FILES missing in repo: #{path}"
    end

    ChangelogDraft::CLIENT_DIR_LABELS.each_key do |dir|
      assert File.directory?(File.join(ROOT, dir)), "CLIENT_DIR_LABELS dir missing in repo: #{dir}"
    end

    ChangelogDraft::SERVER_DIRS.each do |dir|
      assert File.directory?(File.join(ROOT, dir)), "SERVER_DIRS dir missing in repo: #{dir}"
    end
  end

  def test_version_files_contract
    assert_equal(
      %w[
        miniprogram/package.json
        openclacky-ext/cgc-2046/ext.yml
        desktop/Cargo.toml
      ],
      ChangelogDraft::VERSION_FILES
    )
  end

  def test_desktop_only_batch_with_tag_reports_no_server_changes
    analysis = ChangelogDraft.analyze_changes(
      ["desktop/crates/app/src/foo.rs"],
      desktop_tags: ["desktop-v0.1.0-dev.20261121.1"]
    )

    refute analysis[:server_changed]
    assert_includes analysis[:client_dirs], "desktop/（Desktop）"
    assert_empty analysis[:version_hit]

    report = ChangelogDraft.format_report(
      last_merge: { date: "2026-11-21", hash: "5b185133", pr: "1311" },
      commits_summary: { total: 1, kept: ["fix(desktop): desktop only fix"], noise_count: 0 },
      analysis: analysis,
      unreleased: ""
    )

    assert_includes report, "desktop-v0.1.0-dev.20261121.1"
    assert_includes report, "客户端/扩展目录变更：desktop/（Desktop）"
    assert_includes report, "Server 面（backend/web）变更：无"
    assert_includes report, "空——本批无 server 面变更，无需为日期段生成草稿"
  end

  def test_mixed_server_and_client_hits_human_scope_and_deps_image
    analysis = ChangelogDraft.analyze_changes(
      [
        "backend/Dockerfile.deps",
        "backend/config/prod.exs",
        "miniprogram/src/pages/index.tsx",
        "desktop/Cargo.lock"
      ]
    )

    assert analysis[:server_changed]
    assert_includes analysis[:client_dirs], "miniprogram/（小程序（微信/小红书/抖音））"
    assert_includes analysis[:human_hit], "desktop/Cargo.lock"
    assert_includes analysis[:deps_image_hit], "backend/Dockerfile.deps"
    assert_includes analysis[:deps_image_hit], "backend/config/prod.exs"

    report = ChangelogDraft.format_report(
      last_merge: { date: "2026-11-21", hash: "5b185133", pr: "1311" },
      commits_summary: {
        total: 2,
        kept: ["feat(backend): update deps", "feat(mp-wechat): update page"],
        noise_count: 0
      },
      analysis: analysis,
      unreleased: ""
    )

    assert_includes report, "deps-image job 已绿再合 main"
    assert_includes report, "空——需要生成草稿"
  end

  def test_version_files_hit_warning
    files = %w[
      miniprogram/package.json
      openclacky-ext/cgc-2046/ext.yml
      desktop/Cargo.toml
    ]
    analysis = ChangelogDraft.analyze_changes(files)

    assert_equal files, analysis[:version_hit]

    report = ChangelogDraft.format_report(
      last_merge: { date: "2026-11-21", hash: "5b185133", pr: "1311" },
      commits_summary: { total: 1, kept: ["feat(mp-wechat): bump version"], noise_count: 0 },
      analysis: analysis,
      unreleased: ""
    )

    assert_includes report, "客户端版本文件变更：miniprogram/package.json, openclacky-ext/cgc-2046/ext.yml, desktop/Cargo.toml"
    assert_includes report, "独立端节点"
  end

  def test_cli_end_to_end_with_temp_git_repo
    Dir.mktmpdir("changelog-draft-e2e-") do |tmp|
      remote = File.join(tmp, "remote.git")
      clone = File.join(tmp, "clone")

      run_git!("init", "--bare", remote)
      run_git!("clone", remote, clone)
      run_git!("-C", clone, "config", "user.name", "Test User")
      run_git!("-C", clone, "config", "user.email", "test@example.com")
      run_git!("-C", clone, "checkout", "-B", "main")

      File.write(File.join(clone, "CHANGELOG.md"), "## [Unreleased]\n\n## [2026-11-20]\n")
      run_git!("-C", clone, "add", "CHANGELOG.md")
      run_git!("-C", clone, "commit", "-m", "docs(changelog): init")
      run_git!("-C", clone, "push", "-u", "origin", "main")

      run_git!("-C", clone, "checkout", "-b", "develop")
      FileUtils.mkdir_p(File.join(clone, "backend"))
      File.write(File.join(clone, "backend/app.ex"), "defmodule App do\nend\n")
      run_git!("-C", clone, "add", "backend/app.ex")
      run_git!("-C", clone, "commit", "-m", "feat(backend): add endpoint")
      run_git!("-C", clone, "push", "-u", "origin", "develop")

      run_git!("-C", clone, "checkout", "main")
      run_git!("-C", clone, "merge", "--no-ff", "develop", "-m", "Merge pull request #100 from CodingGirlsClub/develop")
      run_git!("-C", clone, "push", "origin", "main")

      run_git!("-C", clone, "checkout", "develop")
      FileUtils.mkdir_p(File.join(clone, "desktop"))
      File.write(File.join(clone, "desktop/README.md"), "# desktop\n")
      run_git!("-C", clone, "add", "desktop/README.md")
      run_git!("-C", clone, "commit", "-m", "fix(desktop): desktop only fix")
      run_git!("-C", clone, "tag", "-a", "desktop-v0.1.0-dev.20261122.1", "-m", "desktop dev build")
      run_git!("-C", clone, "push", "origin", "develop", "--tags")
      run_git!("-C", clone, "fetch", "origin", "main", "develop", "--tags")

      output, status = Open3.capture2e("ruby", SCRIPT, chdir: clone)
      assert status.success?, output
      assert_includes output, "上次发布："
      assert_includes output, "PR #100"
      assert_includes output, "fix(desktop): desktop only fix"
      assert_includes output, "desktop-v0.1.0-dev.20261122.1"
      assert_includes output, "客户端/扩展目录变更：desktop/（Desktop）"
      assert_includes output, "Server 面（backend/web）变更：无"
    end
  end

  private

  def run_git!(*args)
    output, status = Open3.capture2e("git", *args)
    raise "git #{args.join(' ')} failed: #{output}" unless status.success?

    output
  end
end
