defmodule Cgc2046.Workflows.ResearchProgress do
  @moduledoc """
  教研 run 完成判定(切片 H U5, #180;R8 教研半,Q7 discharge)。

  判定 = 目标课程的 ResearchOutput(kind=:issues)已存在 → 教研 run 置
  `succeeded`(内容提交即完成,KTD5:v1 产出确认 = `save_course_content`
  落库成功,无 S1 信号门控)。

  判定数据源纯函数化供 `ResearchProgressWorker` 消费;worker 承担扫描与
  `:complete` 调用(允许 running/waiting → succeeded 直达,KTD3)。
  """
end
