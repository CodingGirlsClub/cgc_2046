defmodule Cgc2046.Repo.Migrations.AddDepositConsentToPaymentsOrders do
  @moduledoc """
  #750 押金同意留痕（#510 同形落列）：押金单的同意事实从一次性请求参数升级为
  订单行上的可审计列——

  - `deposit_consent_at`：押金单创建时（create_for_enrollment 通过同意门）落的
    UTC 时间戳；非押金单恒 NULL。
  - `deposit_terms_version`：同意时点的押金条款版本（`@deposit_terms_version`
    常量单源在 `Cgc2046.Payments.Order`），审计可回答「何时同意的哪一版」，
  同 enrollments 的 `age_confirmed_at` + `terms_version`（#510）形状。

  换渠道（replace_provider）校验被替换押金单的同意事实（`nil` 拒，存量部署前
  单无留痕——窗口有界：expire_at 封顶），新单继承旧单的同意时点与条款版本
  （同一承诺沿单延续，不产生新的同意时点）。

  两列均可空：存量押金单（部署前创建）不回填——它们本就没有可考证的同意事实，
  NULL 即业务事实（replace_provider 据此拒绝换渠道，fail-safe）；非押金单永远
  NULL。无默认值、无索引（留痕只服务 replace 校验与审计读，不在 WHERE 高频列）。
  """

  use Ecto.Migration

  def change do
    alter table(:payments_orders) do
      add :deposit_consent_at, :utc_datetime
      add :deposit_terms_version, :string
    end
  end
end
