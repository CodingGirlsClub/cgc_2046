require "minitest/autorun"
require "yaml"
require "tmpdir"
require "fileutils"
require "open3"
require "digest"
require "json"

class WorkflowHardeningTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_gitleaks_matching_checksum_allows_execution
    with_gitleaks do |root, env, checksum|
      output, status = run_scan(root, env, checksum)
      assert status.success?, output
      assert File.exist?(File.join(root, "extracted")), output
      assert File.exist?(File.join(root, "executed")), output
    end
  end

  def test_gitleaks_mismatching_checksum_stops_before_extraction
    with_gitleaks do |root, env, _checksum|
      output, status = run_scan(root, env, "0" * 64)
      refute status.success?, output
      refute File.exist?(File.join(root, "extracted")), output
      refute File.exist?(File.join(root, "executed")), output
    end
  end

  def test_gitleaks_tampered_archive_stops_before_extraction
    with_gitleaks do |root, env, checksum|
      output, status = run_scan(root, env.merge("TAMPER_ARCHIVE" => "1"), checksum)
      refute status.success?, output
      refute File.exist?(File.join(root, "extracted")), output
      refute File.exist?(File.join(root, "executed")), output
    end
  end

  def test_gitleaks_download_missing_file_and_invalid_digest_fail_closed
    [{"CURL_EXIT" => "22"}, {"MISSING_ARCHIVE" => "1"}, {}].each do |failure|
      with_gitleaks do |root, env, checksum|
        digest = failure.empty? ? "invalid-digest" : checksum
        output, status = run_scan(root, env.merge(failure), digest)
        refute status.success?, output
        refute File.exist?(File.join(root, "extracted")), output
        refute File.exist?(File.join(root, "executed")), output
      end
    end
  end

  def test_gitleaks_unavailable_checksum_tool_stops_before_extraction
    with_gitleaks do |root, env, checksum|
      executable(File.join(root, "bin/sha256sum"), "#!/usr/bin/env bash\nexit 127\n")
      output, status = run_scan(root, env, checksum)
      assert_equal 127, status.exitstatus, output
      refute File.exist?(File.join(root, "extracted")), output
      refute File.exist?(File.join(root, "executed")), output
    end
  end

  def test_gitleaks_failed_extraction_does_not_execute_binary
    with_gitleaks do |root, env, checksum|
      output, status = run_scan(root, env.merge("TAR_EXIT" => "2"), checksum)
      assert_equal 2, status.exitstatus, output
      assert File.exist?(File.join(root, "extracted")), output
      refute File.exist?(File.join(root, "executed")), output
    end
  end

  def test_gitleaks_scan_failure_remains_a_failed_step
    with_gitleaks do |root, env, checksum|
      output, status = run_scan(root, env.merge("SCAN_EXIT" => "42"), checksum)
      assert_equal 42, status.exitstatus, output
      assert File.exist?(File.join(root, "executed")), output
    end
  end

  def test_plugin_sync_python_injection_is_literal_data
    version = %q{0.2.0'; __import__("pathlib").Path("version-executed").touch(); #}
    with_plugin(version) do |mono, market, env, catalog|
      update_catalog(mono, market, env)
      refute File.exist?(File.join(market, "version-executed"))
      catalog["plugins"][0]["version"] = version
      assert_equal catalog, JSON.parse(File.read(File.join(market, ".omp-plugin/marketplace.json"), encoding: Encoding::UTF_8))
    end
  end

  def test_plugin_sync_special_characters_and_unicode_survive_json_update
    ["0.2.0", "quotes'\"slash\\中文", '$(touch shell-executed)`touch shell-executed`'].each do |version|
      with_plugin(version) do |mono, market, env, catalog|
        update_catalog(mono, market, env)
        catalog["plugins"][0]["version"] = version
        assert_equal catalog, JSON.parse(File.read(File.join(market, ".omp-plugin/marketplace.json"), encoding: Encoding::UTF_8))
        refute File.exist?(File.join(market, "shell-executed"))
      end
    end
  end

  def test_plugin_sync_same_version_and_content_does_not_commit_or_push
    with_plugin("0.1.6") do |mono, market, env, _catalog|
      remote = initialize_plugin_git(market)
      original = File.binread(File.join(market, ".omp-plugin/marketplace.json"))
      head = git(market, "rev-parse", "HEAD")
      remote_head = git(market, "--git-dir", remote, "rev-parse", "HEAD")
      update_catalog(mono, market, env)
      assert_equal original, File.binread(File.join(market, ".omp-plugin/marketplace.json"))
      output, status = commit_plugin(mono, market, env)
      assert status.success?, output
      assert_includes output, "No changes to sync"
      assert_equal head, git(market, "rev-parse", "HEAD")
      assert_equal remote_head, git(market, "--git-dir", remote, "rev-parse", "HEAD")
    end
  end

  def test_plugin_sync_new_version_updates_local_remote_catalog
    with_plugin("0.2.0") do |mono, market, env, catalog|
      remote = initialize_plugin_git(market)
      update_catalog(mono, market, env)
      output, status = commit_plugin(mono, market, env)
      assert status.success?, output
      catalog["plugins"][0]["version"] = "0.2.0"
      assert_equal catalog, JSON.parse(git(market, "--git-dir", remote, "show", "main:.omp-plugin/marketplace.json"))
    end
  end

  def test_plugin_sync_changed_plugin_content_pushes_even_when_version_is_unchanged
    with_plugin("0.1.6") do |mono, market, env, _catalog|
      remote = initialize_plugin_git(market)
      File.write(File.join(market, "plugins/cgc-2046/example.txt"), "updated plugin\n")
      update_catalog(mono, market, env)
      output, status = commit_plugin(mono, market, env)
      assert status.success?, output
      assert_equal "updated plugin", git(market, "--git-dir", remote, "show", "main:plugins/cgc-2046/example.txt")
    end
  end

  private

  def steps(workflow, job)
    YAML.load_file(File.join(ROOT, ".github/workflows", workflow)).fetch("jobs").fetch(job).fetch("steps")
  end

  def run_shell(script, env, root)
    Open3.capture2e(env, "bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script,
                   chdir: root, unsetenv_others: true)
  end

  def executable(path, content)
    File.write(path, content)
    File.chmod(0o755, path)
  end

  def with_gitleaks
    Dir.mktmpdir("gitleaks-hardening-") do |root|
      bin = File.join(root, "bin")
      source = File.join(root, "source")
      FileUtils.mkdir_p([bin, source])
      executable(File.join(source, "gitleaks"), <<~'SH')
        #!/usr/bin/env bash
        printf 'executed\n' > "$EXECUTED"
        exit "${SCAN_EXIT:-0}"
      SH
      archive = File.join(root, "fixture.tar.gz")
      output, status = Open3.capture2e("tar", "-czf", archive, "-C", source, "gitleaks")
      raise output unless status.success?
      checksum = Digest::SHA256.file(archive).hexdigest
      executable(File.join(bin, "curl"), <<~'SH')
        #!/usr/bin/env bash
        set -eu
        exit_code="${CURL_EXIT:-0}"
        [ "$exit_code" = 0 ] || exit "$exit_code"
        output=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o|--output) output="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ "${MISSING_ARCHIVE:-0}" = 0 ] || { [ -z "$output" ] || rm -f "$output"; exit 0; }
        if [ -n "$output" ]; then cp "$FIXTURE_ARCHIVE" "$output"; else cat "$FIXTURE_ARCHIVE"; fi
        [ "${TAMPER_ARCHIVE:-0}" = 0 ] || printf 'tampered' >> "$output"
      SH
      executable(File.join(bin, "tar"), <<~'SH')
        #!/usr/bin/env bash
        printf 'extracted\n' > "$EXTRACTED"
        [ "${TAR_EXIT:-0}" = 0 ] || exit "$TAR_EXIT"
        exec "$REAL_TAR" "$@"
      SH
      # macOS lacks GNU sha256sum; this adapter still performs real SHA-256 verification.
      unless ENV.fetch("PATH").split(File::PATH_SEPARATOR).any? { |p| File.executable?(File.join(p, "sha256sum")) }
        executable(File.join(bin, "sha256sum"), "#!/usr/bin/env bash\nexec shasum -a 256 \"$@\"\n")
      end
      real_tar, status = Open3.capture2e("bash", "-c", "command -v tar")
      raise real_tar unless status.success?
      env = {
        "PATH" => "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}",
        "FIXTURE_ARCHIVE" => archive,
        "REAL_TAR" => real_tar.strip,
        "EXTRACTED" => File.join(root, "extracted"),
        "EXECUTED" => File.join(root, "executed")
      }
      yield root, env, checksum
    end
  end

  def run_scan(root, env, checksum)
    step = steps("ci.yml", "secrets").find { |s| s["name"] == "Gitleaks scan" }
    # Only the test process substitutes the fixture digest; CI keeps its official pinned digest.
    run_shell(step.fetch("run"), step.fetch("env", {}).merge(env).merge("GITLEAKS_SHA256" => checksum), root)
  end

  def clean_env
    {"PATH" => ENV.fetch("PATH"), "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"}
  end

  def with_plugin(version)
    Dir.mktmpdir("plugin-sync-hardening-") do |root|
      mono = File.join(root, "monorepo")
      market = File.join(root, "marketplace")
      FileUtils.mkdir_p([File.join(mono, "omp-plugin/cgc-2046"), File.join(market, ".omp-plugin"),
                         File.join(market, "plugins/cgc-2046")])
      File.write(File.join(mono, "omp-plugin/cgc-2046/package.json"), JSON.generate({"version" => version}))
      catalog = {"name" => "女孩学编程", "plugins" => [
        {"name" => "cgc-2046", "version" => "0.1.6", "source" => "plugins/cgc-2046"},
        {"name" => "another-plugin", "version" => "3.0.0"}
      ]}
      File.write(File.join(market, ".omp-plugin/marketplace.json"), JSON.pretty_generate(catalog))
      File.write(File.join(market, "plugins/cgc-2046/example.txt"), "original plugin\n")
      yield mono, market, clean_env, catalog
    end
  end

  def update_catalog(mono, market, env)
    outputs = {}
    version_steps = steps("sync-omp-plugin.yml", "sync").select do |step|
      step["name"].to_s.start_with?("Read version from package.json") || step["name"] == "Update catalog version"
    end
    version_steps.each do |step|
      output_file = File.join(mono, "step-output")
      File.write(output_file, "")
      bindings = step.fetch("env", {}).transform_values do |value|
        match = value.match(/\A\$\{\{ steps\.([a-z_]+)\.outputs\.([A-Z_]+) \}\}\z/)
        match ? outputs.fetch(match[1], {}).fetch(match[2], "") : value
      end
      script = step.fetch("run").gsub("/tmp/cgc-omp-plugins", market)
      output, status = run_shell(script, env.merge(bindings).merge("GITHUB_OUTPUT" => output_file), mono)
      assert status.success?, output
      outputs[step["id"]] = File.readlines(output_file, encoding: Encoding::UTF_8).to_h { |line| line.chomp.split("=", 2) } if step["id"]
    end
  end

  def git(root, *args)
    output, status = Open3.capture2e(clean_env, "git", *args, chdir: root, unsetenv_others: true)
    raise output unless status.success?
    output.force_encoding(Encoding::UTF_8).strip
  end

  def initialize_plugin_git(market)
    remote = File.join(File.dirname(market), "remote.git")
    git(market, "init", "-b", "main")
    git(market, "config", "user.name", "Workflow fixture")
    git(market, "config", "user.email", "fixture@example.com")
    git(market, "config", "commit.gpgsign", "false")
    git(market, "config", "core.hooksPath", "/dev/null")
    git(market, "add", "plugins/cgc-2046", ".omp-plugin/marketplace.json")
    git(market, "commit", "-m", "fixture baseline")
    git(market, "init", "--bare", "--initial-branch=main", remote)
    git(market, "remote", "add", "origin", remote)
    git(market, "push", "origin", "main")
    remote
  end

  def commit_plugin(mono, market, env)
    step = steps("sync-omp-plugin.yml", "sync").find { |s| s["name"] == "Commit and push if changed" }
    script = step.fetch("run").gsub("/tmp/cgc-omp-plugins", market)
                 .gsub("${{ steps.sha.outputs.CGC_SHA }}", "fixture985")
    run_shell(script, env, mono)
  end
end
