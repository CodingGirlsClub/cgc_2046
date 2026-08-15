defmodule Cgc2046.Workflows.StepAuthorizationDecisionTest do
  # 纯函数测试：不碰 DB（async: true 安全）。IO 层（authorize_signal/4 真实读取）见
  # step_authorization_test.exs。
  use ExUnit.Case, async: true

  alias Cgc2046.Workflows.StepAuthorization

  describe "authorize_roles/2 判定矩阵" do
    test "owner/admin 豁免：step 仅授权其他角色时仍放行" do
      assert :ok = StepAuthorization.authorize_roles([:owner], {:ok, [:volunteer]})
      assert :ok = StepAuthorization.authorize_roles([:admin], {:ok, [:volunteer]})
      assert :ok = StepAuthorization.authorize_roles([:learner, :owner], {:ok, [:volunteer]})
    end

    test "多角色并集命中放行" do
      assert :ok =
               StepAuthorization.authorize_roles(
                 [:learner, :volunteer],
                 {:ok, [:owner, :volunteer]}
               )
    end

    test "并集未命中拒绝" do
      assert {:error, :unauthorized} =
               StepAuthorization.authorize_roles([:learner], {:ok, [:owner]})

      assert {:error, :unauthorized} = StepAuthorization.authorize_roles([], {:ok, [:owner]})
    end

    test "未配置（{:ok, []}）不限制" do
      assert :ok = StepAuthorization.authorize_roles([:learner], {:ok, []})
      assert :ok = StepAuthorization.authorize_roles([], {:ok, []})
    end

    test "配置读取失败 fail-closed：{:error, _} → :authorization_unavailable" do
      assert {:error, :authorization_unavailable} =
               StepAuthorization.authorize_roles([:learner], {:error, :db_read_failed})

      assert {:error, :authorization_unavailable} =
               StepAuthorization.authorize_roles([], {:error, %RuntimeError{message: "boom"}})
    end
  end

  describe "error_message/2 文案" do
    test ":unauthorized 文案逐字保持（step_role_test 既有断言兼容）" do
      assert StepAuthorization.error_message(:unauthorized, "approval") ==
               "unauthorized to signal step approval"
    end

    test ":authorization_unavailable 文案" do
      assert StepAuthorization.error_message(:authorization_unavailable, "approval") ==
               "authorization check failed for step approval"
    end
  end

  describe "authorize_signal/5 接线（注入 step_allowed_roles；actor 用 nil 短路角色查询，不碰 DB）" do
    test "配置读取失败 → :authorization_unavailable（fail-closed 接线覆盖）" do
      assert {:error, :authorization_unavailable} =
               StepAuthorization.authorize_signal(nil, "ws", "defn", "approval", fn _, _, _ ->
                 {:error, :db_read_failed}
               end)
    end

    test "nil actor + 有配置 → 拒绝（模块防御语义；生产路径由 workflow_run.ex 的 is_nil(actor) 守卫先拦截）" do
      assert {:error, :unauthorized} =
               StepAuthorization.authorize_signal(nil, "ws", "defn", "approval", fn _, _, _ ->
                 {:ok, [:owner]}
               end)
    end

    test "nil actor + 无配置 → :ok（模块防御语义）" do
      assert :ok =
               StepAuthorization.authorize_signal(nil, "ws", "defn", "approval", fn _, _, _ ->
                 {:ok, []}
               end)
    end
  end
end
