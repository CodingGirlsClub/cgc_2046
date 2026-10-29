require "minitest/autorun"
require "yaml"
require "tmpdir"
require "fileutils"
require "open3"
require "digest"

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
end
