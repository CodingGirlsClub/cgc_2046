directory = Application.fetch_env!(:cgc_2046, :playbooks_dir)
expected_directory = Path.join(:code.priv_dir(:cgc_2046), "playbooks")

unless directory == expected_directory and File.ls!(directory) == ["tutor.md"] do
  raise "unexpected release playbook layout"
end

path = Path.join(directory, "tutor.md")
unless File.lstat!(path).type == :regular, do: raise("invalid release playbook file")
content = File.read!(path)
hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> binary_part(0, 8)
unless hash == System.fetch_env!("EXPECTED_HASH"), do: raise("release hash mismatch")

case Cgc2046.Mcp.Playbooks.fetch(:tutor) do
  {:ok, playbook} ->
    unless String.ends_with?(playbook.version, "+" <> hash) and
             String.ends_with?(playbook.content, String.trim(content)) do
      raise "release playbook did not load supplement"
    end

  _other ->
    raise "release playbook fetch failed"
end

for pattern <- ["/app/**/.git", "/app/**/cgc-playbooks", "/app/**/id_ed25519"] do
  unless Path.wildcard(pattern, match_dot: true) == [], do: raise("unexpected release metadata")
end

IO.puts("release playbook verified")
