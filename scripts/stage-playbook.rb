require "digest"
require "fileutils"

root = File.expand_path(ARGV.fetch(0))
staging = File.join(root, "backend/tmp/cgc-playbooks")
destination = File.join(root, "backend/priv/playbooks")

begin
  raise "invalid staging" unless File.lstat(staging).directory?
  raise "invalid playbooks directory" unless File.lstat(File.join(staging, "playbooks")).directory?

  source = File.join(staging, "playbooks/tutor.md")
  raise "invalid tutor.md" unless File.lstat(source).file?

  content = File.binread(source).force_encoding(Encoding::UTF_8)
  raise "invalid tutor.md" unless content.valid_encoding? && content.match?(/[^[:space:]]/)
  raise "invalid destination" if File.symlink?(destination)

  FileUtils.mkdir_p(destination)
  raise "unexpected playbook files" unless (Dir.children(destination) - ["tutor.md"]).empty?

  target = File.join(destination, "tutor.md")
  raise "invalid destination" if File.symlink?(target)

  File.binwrite(target, content)
  File.chmod(0o600, target)
  hash = Digest::SHA256.hexdigest(content)[0, 8]
ensure
  FileUtils.rm_rf(staging)
end

puts "hash=#{hash}"
