require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "digest"

class StagePlaybookTest < Minitest::Test
  SCRIPT = File.expand_path("../stage-playbook.rb", __dir__)

  def with_checkout
    Dir.mktmpdir do |root|
      staging = File.join(root, "backend/tmp/cgc-playbooks")
      FileUtils.mkdir_p(File.join(staging, "playbooks"))
      File.write(File.join(staging, "README.md"), "private fixture")
      FileUtils.mkdir_p(File.join(staging, ".git"))
      yield root, staging, File.join(staging, "playbooks/tutor.md")
    end
  end

  def test_copies_only_tutor_and_hashes_original_bytes
    with_checkout do |root, staging, source|
      content = "  synthetic tutor fixture\n"
      File.binwrite(source, content)
      output, status = Open3.capture2e("ruby", SCRIPT, root)
      assert status.success?, output
      assert_equal "hash=#{Digest::SHA256.hexdigest(content)[0, 8]}\n", output
      directory = File.join(root, "backend/priv/playbooks")
      assert_equal ["tutor.md"], Dir.children(directory)
      assert_equal content, File.binread(File.join(directory, "tutor.md"))
      refute File.exist?(staging)
    end
  end

  def test_rejects_missing_blank_invalid_directory_and_symlink
    [:missing, :blank, :invalid, :directory, :symlink].each do |kind|
      with_checkout do |root, staging, source|
        case kind
        when :blank then File.write(source, " \n\t　")
        when :invalid then File.binwrite(source, "private fixture\xff")
        when :directory then FileUtils.mkdir_p(source)
        when :symlink then File.symlink(File.join(staging, "README.md"), source)
        end
        output, status = Open3.capture2e("ruby", SCRIPT, root)
        refute status.success?, kind.to_s
        refute_includes output, "private fixture"
        refute_includes output, "hash="
        refute File.exist?(staging)
        refute File.exist?(File.join(root, "backend/priv/playbooks/tutor.md"))
      end
    end
  end

  def test_different_content_changes_hash
    hashes = ["first fixture", "second fixture"].map do |content|
      with_checkout do |root, _staging, source|
        File.write(source, content)
        output, status = Open3.capture2e("ruby", SCRIPT, root)
        assert status.success?, output
        output
      end
    end
    refute_equal hashes.first, hashes.last
  end
end
