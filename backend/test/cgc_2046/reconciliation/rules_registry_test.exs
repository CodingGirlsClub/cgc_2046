defmodule Cgc2046.Reconciliation.RulesRegistryTest do
  @moduledoc """
  #852 C9 反射锁：注册表 = Finding 枚举全集、scan worker 声明表与注册表
  一致、各生产方源文件使用的 rule atom ∈ 注册表、声明字段完备。

  堵「atom 拼错静默漏报」类缺陷：写 Finding 撞 one_of 约束后 handle_write
  只 Logger.warning（静默漏报），无「分发表 ⊆ 枚举」断言——本测试用全集
  断言先堵类（运行时升级另议，issue #852 Q6）。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Payments.Workers.DepositForfeitWorker
  alias Cgc2046.Payments.Workers.PaymentReconciliationWorker
  alias Cgc2046.Payments.Workers.PaymentSettlementWorker
  alias Cgc2046.Reconciliation.Finding
  alias Cgc2046.Reconciliation.ReconciliationScanWorker
  alias Cgc2046.Reconciliation.RulesRegistry

  @producers [
    ReconciliationScanWorker,
    DepositForfeitWorker,
    PaymentSettlementWorker,
    PaymentReconciliationWorker
  ]

  describe "注册表 = Finding 枚举全集" do
    test "ids/0 集合 == Finding.rule_values/0（堵 atom 拼错静默漏报）" do
      assert MapSet.new(RulesRegistry.ids()) == MapSet.new(Finding.rule_values())
    end

    test "id 无重复声明" do
      ids = RulesRegistry.ids()
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "声明字段完备：desc 非空、sweep 合法、producer 为真实模块" do
      for rule <- RulesRegistry.all() do
        assert is_binary(rule.desc) and rule.desc != "", "#{rule.id}: desc 空"
        assert rule.sweep in [:full, :partial, :one_shot], "#{rule.id}: sweep 非法"
        assert is_atom(rule.producer) and Code.ensure_loaded?(rule.producer)
      end
    end

    test "四个生产方在注册表均有声明（空集假绿防线）" do
      for producer <- @producers do
        assert RulesRegistry.by_producer(producer) != []
      end
    end
  end

  describe "scan worker 声明表与注册表一致" do
    test "rules/0 的 id 集 == by_producer(ReconciliationScanWorker) 的 id 集" do
      worker_ids = ReconciliationScanWorker.rules() |> Enum.map(& &1.id) |> MapSet.new()

      registry_ids =
        RulesRegistry.by_producer(ReconciliationScanWorker) |> Enum.map(& &1.id) |> MapSet.new()

      assert worker_ids == registry_ids
    end

    test "rules/0 每条声明字段完备（id/desc/sweep/detect 四键 + detect 为 0 元函数）" do
      for rule <- ReconciliationScanWorker.rules() do
        assert MapSet.new(Map.keys(rule)) == MapSet.new([:id, :desc, :sweep, :detect])
        assert is_function(rule.detect, 0)
      end
    end
  end

  describe "各生产方源文件使用的 rule atom ∈ 注册表" do
    test "逐生产方提取（@rule/@batch_alert_rule 属性、apply_rule 字面量、%{id: 声明）" do
      registry_ids = MapSet.new(RulesRegistry.ids())

      for producer <- @producers do
        {extracted, source_path} = producer_atoms(producer)

        assert extracted != [], "#{inspect(producer)}: 未提取到任何 rule atom（提取器失效？）"

        for atom <- extracted do
          assert atom in registry_ids,
                 "#{inspect(producer)} 使用了未注册规则 #{inspect(atom)}（#{source_path}）"
        end
      end
    end
  end

  # 源文件静态提取：覆盖四个生产方当前的全部 rule atom 书写形态——
  #   ① @rule / @batch_alert_rule 属性定义（deposit / payment_recon）
  #   ② Finding.apply_rule(:atom 字面量调用（settlement）
  #   ③ %{id: :atom 声明表条目（scan worker rules/0）
  # 新生产方/新书写形态出现时在此扩模式（白名单式提取，非全量语法分析）。
  defp producer_atoms(producer) do
    source_path = producer.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()
    source = File.read!(source_path)

    patterns = [
      ~r/@(?:rule|batch_alert_rule)\s+:(\w+)/,
      ~r/apply_rule\(\s*:(\w+)/,
      ~r/%\{id:\s*:(\w+)/
    ]

    atoms =
      patterns
      |> Enum.flat_map(&Regex.scan(&1, source, capture: :all_but_first))
      |> List.flatten()
      |> Enum.map(&String.to_atom/1)
      |> Enum.uniq()

    {atoms, source_path}
  end
end
