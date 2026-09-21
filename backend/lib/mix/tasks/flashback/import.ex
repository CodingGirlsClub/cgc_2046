defmodule Mix.Tasks.Flashback.Import do
  @shortdoc "Import legacy Excel sign-up sheets into Flashback (dry-run by default)"

  @moduledoc """
  闪念间一次性导入任务（U3，R22）：Excel → 标记语法解析 → Flashback 档案。

  ## 用法

      # dry-run（默认）：只产报告，不写库
      mix flashback.import /path/to/2014.1.11RailsGirlsChina.xlsx

      # 真跑（先人工签收 dry-run 报告）
      mix flashback.import /path/to/file.xlsx --commit

      # 覆盖列映射（各城表头差异）：传 Elixir map 字面量
      mix flashback.import /path/to/file.xlsx --config 'sheet: "报名", columns: %{"名字" => :full_name}'

  ## 行为

  - 入口 fail-closed 判定真实格式（magic bytes）：BIFF8 `.xls`（OLE2）直接
    报错并给转换指引（Excel/LibreOffice 另存 .xlsx 或
    `soffice --convert-to xlsx`）——本批源文件扩展名与真实格式已错位（R22）；
  - 参与状态：行在录取名单 sheet（默认「学生」）内 = attended（记忆线），
    否则 not_selected（圆梦线）；手机号优先匹配，姓名+城市兜底；
  - 两份录取名单（「学生」vs「工作表1」）真源差异进 dry-run 报告人工签收；
  - 雾面标记语法见 `docs/运维/闪念间雾化标记语法.md`；
  - 结构化 PII（姓名/手机/邮箱）自动整段雾化，无需离线处理。

  ## 退出码

  - 0：dry-run 报告产出（或 --commit 落库完成）；
  - 1：格式错误 / sheet 缺失 / 标记解析失败（报告含行级定位）。

  真实 PII 文件路径不进仓、不进日志（仅本次运行使用）。
  """

  use Mix.Task

  alias Cgc2046.Flashback.Import

  @impl true
  def run([]) do
    Mix.raise("Usage: mix flashback.import <path-to-xlsx> [--commit] [--config '…']")
  end

  def run(args) do
    {opts, [path], _invalid} =
      OptionParser.parse(args, strict: [commit: :boolean, config: :string])

    Mix.Task.run("app.start", [])

    config =
      case Keyword.get(opts, :config) do
        nil -> %{}
        code -> Code.eval_string(code) |> elem(0)
      end

    case File.read(path) do
      {:ok, binary} ->
        run_import(binary, dry_run: not Keyword.get(opts, :commit, false), config: config)

      {:error, reason} ->
        Mix.raise("无法读取 #{path}: #{inspect(reason)}")
    end
  end

  defp run_import(binary, opts) do
    case Import.run(binary, opts) do
      {:ok, report} ->
        print_report(report)
        Mix.shell().info("\n[dry-run] 未写库。人工签收报告后加 --commit 真跑。")

      {:ok, report, counts} ->
        print_report(report)
        Mix.shell().info("\n[commit] 落库完成: #{counts.people} 人 / #{counts.answers} 条答案")

      {:error, {:biff8, hint}} ->
        Mix.raise("源文件是 BIFF8 (.xls)——#{hint}")

      {:error, reason} ->
        Mix.raise("导入失败: #{inspect(reason, pretty: true, limit: 50)}")
    end
  end

  defp print_report(report) do
    Mix.shell().info("""
    ── 闪念间导入 dry-run 报告 ──────────────────────────────
    源格式:        #{report.source_format}
    场次:          #{report.archive[:key]}（#{report.archive[:name]}）
    城市过滤:      #{report.city_filter || "无（全量）"}
    数据 sheet:    #{report.sheet}
    数据行:        #{report.rows_total}（姓名缺失跳过 #{report.rows_skipped_missing_name}）
    待导入人数:    #{report.people_to_import}
    参与状态:      记忆线 #{report.participation.attended} / 圆梦线 #{report.participation.not_selected}（判定源: #{report.attendance_source}）
    名单真源裁决:  仅在「#{report.attendance_source}」#{report.roster_reconciliation.only_in_primary} 人 / 仅在「#{report.roster_reconciliation.alt_sheet}」#{report.roster_reconciliation.only_in_alt} 人 ← 人工签收
    触达覆盖:      手机 #{report.contact_coverage.with_phone} / 邮箱 #{report.contact_coverage.with_email}（空手机有邮箱 #{report.contact_coverage.empty_phone_with_email}）
    报名时间:      解析成功 #{report.applied_at.parsed} / 失败 #{length(report.applied_at.failed)}
    雾化:          残留标记 #{report.fog.residual_markers}（必须 0）/ 非法区间 #{report.fog.invalid_spans}（必须 0）/ span 总数 #{report.fog.spans_total} / 覆盖答案行 #{report.fog.rows_fogged}
                  结构化 PII 自动雾化 #{report.fog.pii_answers_auto_fogged} 行
    库内已有此场次人数: #{report.existing_people_in_archive}（>0 时 --commit 会叠加，须先裁决）
    """)
  end
end
