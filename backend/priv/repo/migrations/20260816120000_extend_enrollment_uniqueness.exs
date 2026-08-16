defmodule Cgc2046.Repo.Migrations.ExtendEnrollmentUniquenessWithPaymentPending do
  @moduledoc """
  缴费闭环 U3：防重复报名部分唯一索引扩列 payment_pending（KTD6）。

  payment_pending 与 pending/confirmed 同为「活跃报名」窗口——已占位待支付的
  用户不得再报同一目标（名额不可叠加），与资源 identity_wheres_to_sql 同步。
  """

  use Ecto.Migration

  @event_index "enrollments_unique_event_user_index"
  @course_index "enrollments_unique_course_user_index"

  def up do
    execute("DROP INDEX #{@event_index}")

    execute(
      "CREATE UNIQUE INDEX #{@event_index} ON enrollments (event_id, user_id) " <>
        "WHERE event_id IS NOT NULL AND status IN ('pending', 'payment_pending', 'confirmed')"
    )

    execute("DROP INDEX #{@course_index}")

    execute(
      "CREATE UNIQUE INDEX #{@course_index} ON enrollments (course_id, user_id) " <>
        "WHERE course_id IS NOT NULL AND status IN ('pending', 'payment_pending', 'confirmed')"
    )
  end

  def down do
    execute("DROP INDEX #{@event_index}")

    execute(
      "CREATE UNIQUE INDEX #{@event_index} ON enrollments (event_id, user_id) " <>
        "WHERE event_id IS NOT NULL AND status IN ('pending', 'confirmed')"
    )

    execute("DROP INDEX #{@course_index}")

    execute(
      "CREATE UNIQUE INDEX #{@course_index} ON enrollments (course_id, user_id) " <>
        "WHERE course_id IS NOT NULL AND status IN ('pending', 'confirmed')"
    )
  end
end
