ExUnit.start()
source_root = System.get_env("VERIFY_CANDIDATE_ROOT", Path.expand("../..", __DIR__))
Code.require_file(Path.join(source_root, "backend/lib/cgc_2046/mcp/playbooks.ex"))

defmodule VerifyReleasePlaybookTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "release-check-#{System.unique_integer([:positive])}")
    library = Path.join(root, "cgc_2046-0.0.0")
    ebin = Path.join(library, "ebin")
    directory = Path.join(library, "priv/playbooks")
    File.mkdir_p!(ebin)
    File.mkdir_p!(directory)
    true = Code.prepend_path(ebin)
    Application.put_env(:cgc_2046, :playbooks_dir, directory)
    content = "synthetic verification content\n"
    File.write!(Path.join(directory, "tutor.md"), content)
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    System.put_env("EXPECTED_HASH", hash)

    on_exit(fn ->
      Code.delete_path(ebin)
      Application.delete_env(:cgc_2046, :playbooks_dir)
      System.delete_env("EXPECTED_HASH")
      File.rm_rf!(root)
    end)

    %{directory: directory}
  end

  test "accepts readable supplement and matching runtime version" do
    assert ExUnit.CaptureIO.capture_io(fn -> verify() end) =~ "release playbook verified"
  end

  test "rejects wrong hash without echoing content" do
    System.put_env("EXPECTED_HASH", "00000000")
    assert_raise RuntimeError, "release hash mismatch", fn -> verify() end
  end

  test "rejects extra private files", %{directory: directory} do
    File.write!(Path.join(directory, "README.md"), "synthetic private metadata")
    assert_raise RuntimeError, "unexpected release playbook layout", fn -> verify() end
  end

  test "rejects a symlink", %{directory: directory} do
    path = Path.join(directory, "tutor.md")
    File.rm!(path)
    File.ln_s!("/nonexistent", path)
    assert_raise RuntimeError, "invalid release playbook file", fn -> verify() end
  end

  defp verify do
    Code.eval_file(Path.expand("../verify-release-playbook.exs", __DIR__))
  end
end
