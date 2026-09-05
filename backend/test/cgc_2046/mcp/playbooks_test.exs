defmodule Cgc2046.Mcp.PlaybooksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Cgc2046.Mcp.Playbooks

  @app :cgc_2046
  @config_key :playbooks_dir

  setup do
    original_config = Application.fetch_env(@app, @config_key)

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "cgc-2046-playbooks-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      restore_env(original_config)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "有效 tutor.md 只追加到 tutor，并从文件内容派生版本", %{tmp_dir: tmp_dir} do
    Application.put_env(@app, @config_key, Path.join(tmp_dir, "missing"))
    assert {:ok, base} = Playbooks.fetch(:tutor)

    supplement = "  私有教研方法论\n"
    File.write!(Path.join(tmp_dir, "tutor.md"), supplement)
    Application.put_env(@app, @config_key, tmp_dir)

    expected_hash =
      :sha256
      |> :crypto.hash(supplement)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    assert {:ok, tutor} = Playbooks.fetch(:tutor)
    assert tutor.content == String.trim_trailing(base.content) <> "\n\n私有教研方法论"
    assert tutor.version == base.version <> "+" <> expected_hash
  end

  test "全空白 tutor.md 记录不含正文的 warning 并回落基础版本", %{tmp_dir: tmp_dir} do
    Application.put_env(@app, @config_key, Path.join(tmp_dir, "missing"))
    assert {:ok, base} = Playbooks.fetch(:tutor)

    File.write!(Path.join(tmp_dir, "tutor.md"), "  \n\t")
    Application.put_env(@app, @config_key, tmp_dir)

    log =
      capture_log(fn ->
        assert {:ok, ^base} = Playbooks.fetch(:tutor)
      end)

    assert log =~ "blank"
    refute log =~ "\t"
  end

  test "非法 UTF-8 记录类别但不泄漏正文，并回落基础版本", %{tmp_dir: tmp_dir} do
    Application.put_env(@app, @config_key, Path.join(tmp_dir, "missing"))
    assert {:ok, base} = Playbooks.fetch(:tutor)

    secret = "PRIVATE-LEAK-SENTINEL"
    File.write!(Path.join(tmp_dir, "tutor.md"), <<255>> <> secret)
    Application.put_env(@app, @config_key, tmp_dir)

    log =
      capture_log(fn ->
        assert {:ok, ^base} = Playbooks.fetch(:tutor)
      end)

    assert log =~ "invalid_utf8"
    refute log =~ secret
  end

  test "symlink tutor.md 不跟随目标且 warning 不泄漏目标正文", %{tmp_dir: tmp_dir} do
    Application.put_env(@app, @config_key, Path.join(tmp_dir, "missing"))
    assert {:ok, base} = Playbooks.fetch(:tutor)

    secret = "PRIVATE-SYMLINK-SENTINEL"
    target = Path.join(tmp_dir, "private-target.md")
    File.write!(target, secret)
    File.ln_s!(target, Path.join(tmp_dir, "tutor.md"))
    Application.put_env(@app, @config_key, tmp_dir)

    log =
      capture_log(fn ->
        assert {:ok, ^base} = Playbooks.fetch(:tutor)
      end)

    assert log =~ "symlink"
    refute log =~ secret
  end

  test "非普通 tutor.md 记录 warning 并回落基础版本", %{tmp_dir: tmp_dir} do
    Application.put_env(@app, @config_key, Path.join(tmp_dir, "missing"))
    assert {:ok, base} = Playbooks.fetch(:tutor)

    File.mkdir!(Path.join(tmp_dir, "tutor.md"))
    Application.put_env(@app, @config_key, tmp_dir)

    log =
      capture_log(fn ->
        assert {:ok, ^base} = Playbooks.fetch(:tutor)
      end)

    assert log =~ "not_regular"
  end

  test "读取 tutor.md 失败时记录类别但不泄漏正文，并回落基础版本", %{tmp_dir: tmp_dir} do
    Application.put_env(@app, @config_key, Path.join(tmp_dir, "missing"))
    assert {:ok, base} = Playbooks.fetch(:tutor)

    secret = "PRIVATE-READ-ERROR-SENTINEL"
    path = Path.join(tmp_dir, "tutor.md")
    File.write!(path, secret)
    File.chmod!(path, 0o000)
    Application.put_env(@app, @config_key, tmp_dir)

    log =
      capture_log(fn ->
        assert {:ok, ^base} = Playbooks.fetch(:tutor)
      end)

    assert log =~ "read_error"
    refute log =~ secret
  end

  test "未配置目录与缺失 tutor.md 均返回四角色公开基础版本且缺失不记 warning", %{
    tmp_dir: tmp_dir
  } do
    Application.delete_env(@app, @config_key)

    baselines =
      Map.new(Playbooks.roles(), fn role ->
        assert {:ok, playbook} = Playbooks.fetch(role)
        {role, playbook}
      end)

    Application.put_env(@app, @config_key, Path.join(tmp_dir, "missing"))

    log =
      capture_log(fn ->
        for {role, baseline} <- baselines do
          assert {:ok, ^baseline} = Playbooks.fetch(role)
        end
      end)

    assert log == ""
  end

  test "非 tutor 角色从不读取目录中的同名私有文件", %{tmp_dir: tmp_dir} do
    roles = [:learner, :workspace_admin, :platform_admin]
    Application.put_env(@app, @config_key, Path.join(tmp_dir, "missing"))

    baselines =
      Map.new(roles, fn role ->
        assert {:ok, playbook} = Playbooks.fetch(role)
        {role, playbook}
      end)

    for role <- roles do
      File.write!(Path.join(tmp_dir, "#{role}.md"), "PRIVATE-#{role}")
    end

    Application.put_env(@app, @config_key, tmp_dir)

    for {role, baseline} <- baselines do
      assert {:ok, ^baseline} = Playbooks.fetch(role)
    end
  end

  test "相同 tutor.md 版本稳定，文件内容变化后版本随之变化", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "tutor.md")
    Application.put_env(@app, @config_key, tmp_dir)

    File.write!(path, "方法论 A\n")
    assert {:ok, first} = Playbooks.fetch(:tutor)
    assert {:ok, repeated} = Playbooks.fetch(:tutor)
    assert repeated.version == first.version

    File.write!(path, "方法论 B\n")
    assert {:ok, changed} = Playbooks.fetch(:tutor)
    refute changed.version == first.version
  end

  test "未知角色保持 unknown_role 契约" do
    assert {:ok, :tutor} = Playbooks.normalize_role(:tutor)
    assert {:ok, :tutor} = Playbooks.normalize_role("tutor")
    assert {:error, :unknown_role} = Playbooks.normalize_role(:observer)
    assert {:error, :unknown_role} = Playbooks.normalize_role("observer")
    assert {:error, :unknown_role} = Playbooks.normalize_role(nil)

    assert {:error, :unknown_role} = Playbooks.fetch(:observer)
    assert {:error, :unknown_role} = Playbooks.fetch("observer")
    assert {:error, :unknown_role} = Playbooks.fetch(nil)
    assert {:error, :unknown_role} = Playbooks.version(:observer)
  end

  test "test 环境使用固定不存在目录，不读取 CGC_PLAYBOOKS_DIR", %{tmp_dir: tmp_dir} do
    original_system_env = System.get_env("CGC_PLAYBOOKS_DIR")
    on_exit(fn -> restore_system_env("CGC_PLAYBOOKS_DIR", original_system_env) end)

    File.write!(Path.join(tmp_dir, "tutor.md"), "不应进入 test 的私有内容")
    System.put_env("CGC_PLAYBOOKS_DIR", tmp_dir)

    expected_dir = Path.expand("../../support/playbooks-missing", __DIR__)
    assert Application.fetch_env!(@app, @config_key) == expected_dir
    refute File.exists?(expected_dir)

    assert {:ok, tutor} = Playbooks.fetch(:tutor)
    refute tutor.version =~ "+"
    refute tutor.content =~ "不应进入 test 的私有内容"
  end

  defp restore_env({:ok, value}), do: Application.put_env(@app, @config_key, value)
  defp restore_env(:error), do: Application.delete_env(@app, @config_key)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
