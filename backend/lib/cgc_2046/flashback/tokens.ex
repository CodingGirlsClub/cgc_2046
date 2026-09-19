defmodule Cgc2046.Flashback.Tokens do
  @moduledoc """
  首程 token 读写面（U2，KTD2）：链接即身份的免登录全套流程。

  token 定位走 `Cgc2046.Accounts.TokenCredential.fetch/2`（`authorize?: false` +
  token_hash 精确匹配——token 持有者非成员，read policy 不适用），随后本模块
  对 token 状态显式复验（已注册 / 已删除 / 不存在三态可区分，R1）；一切写
  路径均为服务端 `authorize?: false`（资源 policy 只放行 PlatformAdmin，token
  面不经 policy——防匿名绕过的闸门在 token 本身的熵与限流）。

  ## 四时刻行为事件（KTD10）

  - `link_opened`：`enter/1` 成功；
  - `revealed`：`mark_revealed/1`（前端认领显影完成时调用——其余三事件由后端
    在对应 mutation 内写入，防客户端伪造刷率）；
  - `sent_to_wall`：`send_to_wall/1`（幂等：重复寄出不重复计）；
  - `intent_submitted`：`submit_today/2`。

  ## 投影纪律（KTD3）

  本模块产出的响应 DTO 一律白名单列字段；`phone` / `email` 明文绝不出现，
  只有 `PhoneNumber.mask/1` 后的掩码（确认页回显，KTD7）。

  ## 错误码（#241 契约）

  业务 code 在本模块以字面量出现，经 `mix cgc2046.gen_error_codes_contract`
  进契约；web 文案在 `web/messages/*.json` errors namespace。
  """

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.{PhoneNumber, PhoneVerificationCode, SignInFlow, TokenCredential}
  alias Cgc2046.Flashback.{Answer, Person, QuoteLicense, Today, Token, Touch}
  alias Cgc2046.Mailer

  @touch_events [:link_opened, :revealed, :sent_to_wall, :intent_submitted]

  # ── token 定位与状态 ──────────────────────────────────────────────────

  @doc """
  token → 有效 token 记录（含 person 已加载）。

  三态失效可区分（R1）：不存在 / 已注册（账号接管）/ 已删除。
  """
  @spec fetch_valid(term()) ::
          {:ok, Token.t()} | {:error, %{code: String.t(), message: String.t()}}
  def fetch_valid(token_plaintext) do
    case TokenCredential.fetch(Token, token_plaintext) do
      {:ok, token} ->
        cond do
          not is_nil(token.claimed_by_user_id) ->
            {:error, invalid(code: "flashback_token_claimed", reason: :claimed)}

          not is_nil(token.revoked_at) ->
            {:error, invalid(code: "flashback_token_revoked", reason: :revoked)}

          true ->
            Ash.load(token, :person, authorize?: false)
        end

      {:error, :invalid_token} ->
        {:error, invalid(code: "flashback_token_not_found", reason: :not_found)}

      {:error, other} ->
        {:error, other}
    end
  end

  @doc """
  Ash 校验错误信封（#241：`code` 字面量留在 domain 层进契约；web 手写
  resolver 对 Ash.Error.Invalid 统一经此包装，避免 code 漂移）。
  """
  @spec invalid_input_error(String.t()) :: %{
          code: String.t(),
          message: String.t(),
          reason: atom()
        }
  def invalid_input_error(message) do
    %{code: "flashback_invalid_input", message: message, reason: :invalid_input}
  end

  defp invalid(code: code, reason: reason) do
    %{
      code: code,
      message: "flashback token is not usable (#{reason})",
      reason: reason
    }
  end

  # ── 进入与分流（R1/R2） ──────────────────────────────────────────────

  @doc """
  进入首程：写 `link_opened`，返回分流（记忆线/圆梦线）+ 本人档案投影 +
  进度快照。未注册 token 可反复进入，进度随行（R1）。
  """
  @spec enter(term()) :: {:ok, map()} | {:error, term()}
  def enter(token_plaintext) do
    with {:ok, token} <- fetch_valid(token_plaintext) do
      person =
        token.person
        |> Ash.load!([:answers, :archive_event, :today, :quote_license], authorize?: false)

      record_touch(token, :link_opened)

      {:ok,
       %{
         status: "ok",
         reason: nil,
         line: line_for(person),
         profile: profile_payload(person),
         progress: progress_payload(person),
         scatter: scatter_payload(person)
       }}
    end
  end

  @doc "认领显影完成（四时刻之二）；幂等追加，无业务副作用。"
  @spec mark_revealed(term()) :: {:ok, map()} | {:error, term()}
  def mark_revealed(token_plaintext) do
    with {:ok, token} <- fetch_valid(token_plaintext) do
      record_touch(token, :revealed)
      {:ok, %{recorded: true}}
    end
  end

  # ── 今天的你（R8/R13/R17-R20） ──────────────────────────────────────

  @doc """
  提交「今天的你」（覆盖式）：首次建行、其后更新（每人一行）；写
  `intent_submitted`。联系方式不在本面——更新必须走 `update_contact/3`
  的验证通道（KTD7 防劫持）。
  """
  @spec submit_today(term(), map()) :: {:ok, Today.t()} | {:error, term()}
  def submit_today(token_plaintext, params) do
    with {:ok, token} <- fetch_valid(token_plaintext) do
      submit_today_as_person(token.person_id, params, token)
    end
  end

  @doc """
  「今天的你」编辑——会话面（U9/R28 小程序回访）：与 token 面共用 upsert；
  不写 `intent_submitted`（四率度量首程漏斗，回访编辑不重计）。
  """
  @spec submit_today_as_person(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def submit_today_as_person(person_id, params) do
    submit_today_as_person(person_id, params, nil)
  end

  defp submit_today_as_person(person_id, params, token) do
    with {:ok, today} <- upsert_today(person_id, params) do
      if token, do: record_touch(token, :intent_submitted)
      {:ok, %{today: today_payload(today)}}
    end
  end

  defp upsert_today(person_id, params) do
    case Today
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(person_id == ^person_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Today
        |> Ash.Changeset.for_create(:create, Map.put(params, :person_id, person_id))
        |> Ash.create(authorize?: false)

      {:ok, today} ->
        today
        |> Ash.Changeset.for_update(:update, params)
        |> Ash.update(authorize?: false)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── 寄出与撤下（R11/R30） ────────────────────────────────────────────

  @doc """
  寄出上墙：幂等（已寄出直接返回，不重复计 touch）；无回信行也允许寄出
  （当年正面自成卡）。返回注册引导所需信息（掩码手机号，R27）。
  """
  @spec send_to_wall(term()) :: {:ok, map()} | {:error, term()}
  def send_to_wall(token_plaintext) do
    with {:ok, token} <- fetch_valid(token_plaintext) do
      today = ensure_today(token.person_id)

      if today.sent_to_wall_at do
        {:ok, wall_result(token.person, today)}
      else
        {:ok, today} =
          today
          |> Ash.Changeset.for_update(:update, %{sent_to_wall_at: DateTime.utc_now()})
          |> Ash.update(authorize?: false)

        record_touch(token, :sent_to_wall)
        {:ok, wall_result(token.person, today)}
      end
    end
  end

  @doc "撤下（R30 免注册一键）：sent_to_wall_at 清回 nil，名册回到结构化卡。"
  @spec retract(term()) :: {:ok, map()} | {:error, term()}
  def retract(token_plaintext) do
    with {:ok, token} <- fetch_valid(token_plaintext) do
      case Today
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(person_id == ^token.person_id)
           |> Ash.read_one(authorize?: false) do
        {:ok, nil} ->
          {:ok, %{retracted: true, sent_to_wall_at: nil}}

        {:ok, today} ->
          {:ok, today} =
            today
            |> Ash.Changeset.for_update(:update, %{sent_to_wall_at: nil})
            |> Ash.update(authorize?: false)

          {:ok, %{retracted: true, sent_to_wall_at: today.sent_to_wall_at}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── 雾面调整（R16/KTD4） ─────────────────────────────────────────────

  @doc """
  调整雾面区间：只改 `fog_spans`（`adjust_fog` action 不接受 raw_text——原文
  不可达）；越界/重叠由资源层 `FogSpans.validate/2` 拒绝。
  他人答案 → 与不存在同一错误（不泄露存在性）。
  """
  @spec adjust_fog(term(), String.t(), [map()]) :: {:ok, Answer.t()} | {:error, term()}
  def adjust_fog(token_plaintext, answer_id, spans) do
    with {:ok, token} <- fetch_valid(token_plaintext) do
      adjust_fog_as_person(token.person_id, answer_id, spans)
    end
  end

  @doc "雾面调整——会话面（U9/R28 小程序回访编辑）：与 token 面同规则。"
  @spec adjust_fog_as_person(String.t(), String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def adjust_fog_as_person(person_id, answer_id, spans) do
    with {:ok, answer} <- owned_answer(person_id, answer_id) do
      answer
      |> Ash.Changeset.for_update(:adjust_fog, %{fog_spans: spans})
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, updated} ->
          {:ok, %{answer_id: updated.id, fog_spans: Enum.map(updated.fog_spans, &span_payload/1)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  今天的你句级雾面调整（U10 第二刀）：field ∈ now/want/need/say，spans 与
  当年 FogSpans 同坐标同校验（越界/重叠拒），落 flashback_todays.fog_spans[field]。
  """
  @today_fog_fields ~w(now want need say)

  def adjust_today_fog(token_plaintext, field, spans) do
    with {:ok, token} <- fetch_valid(token_plaintext) do
      adjust_today_fog_as_person(token.person_id, field, spans)
    end
  end

  @spec adjust_today_fog_as_person(String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def adjust_today_fog_as_person(person_id, field, spans)
      when field in @today_fog_fields do
    today = ensure_today(person_id)

    case Cgc2046.Flashback.FogSpans.validate(spans, Map.get(today, today_field(field)) || "") do
      {:ok, _normalized} ->
        next_fog =
          today.fog_spans
          |> Kernel.||(%{})
          |> Map.put(field, normalize_span_payloads(spans))

        today
        |> Ash.Changeset.for_update(:update, %{fog_spans: next_fog})
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, updated} ->
            {:ok, %{field: field, fog_spans: updated.fog_spans}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _reason} ->
        {:error, span_out_of_bounds_error()}
    end
  end

  def adjust_today_fog_as_person(_person_id, field, _spans) do
    {:error,
     %{
       code: "flashback_invalid_today_field",
       message: "invalid today field",
       reason: :invalid_today_field,
       field: field
     }}
  end

  defp today_field("now"), do: :now_status
  defp today_field(field) when field in ~w(want need say), do: String.to_existing_atom(field)

  defp span_out_of_bounds_error do
    %{
      code: "flashback_fog_span_out_of_bounds",
      message: "today fog span is out of bounds for the field text",
      reason: :quote_span_out_of_bounds
    }
  end

  defp normalize_span_payloads(spans) do
    Enum.map(List.wrap(spans || []), fn span ->
      %{
        "start" => span["start"] || span[:start],
        "len" => span["len"] || span[:len]
      }
    end)
  end

  # 金句宿主原文：当年答案（Answer 表）优先；today.now/want/need/say 回落
  # flashback_todays 对应字段（U10 第二刀——今天与当年同一套坐标/校验）。
  defp quote_host_text(person_id, "today." <> field) when field in @today_fog_fields do
    case Today
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(person_id == ^person_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> :error
      {:ok, today} -> {:ok, Map.get(today, today_field(field)) || ""}
    end
  end

  defp quote_host_text(person_id, question_key) do
    case Answer
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(person_id == ^person_id and question_key == ^question_key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> :error
      {:ok, answer} -> {:ok, answer.raw_text}
    end
  end

  defp owned_answer(person_id, answer_id) do
    case Ash.get(Answer, answer_id, authorize?: false) do
      {:ok, %Answer{person_id: owner_id} = answer} when owner_id == person_id ->
        {:ok, answer}

      _ ->
        {:error,
         %{
           code: "flashback_answer_not_found",
           message: "answer not found",
           reason: :answer_not_found
         }}
    end
  end

  # ── 金句授权（R31） ──────────────────────────────────────────────────

  @doc """
  设置金句授权（每人一行，默认 `:off`——两档皆关）。`:anonymous` / `:credited`
  且给出区间时，对来源答案做越界校验（金句候选只允许指向本人答案）。
  """
  @spec set_quote_license(term(), map()) :: {:ok, QuoteLicense.t()} | {:error, term()}
  def set_quote_license(token_plaintext, params) do
    with {:ok, token} <- fetch_valid(token_plaintext) do
      set_quote_license_as_person(token.person_id, params)
    end
  end

  @doc "金句授权——会话面（U9/R31 端内入口）：与 token 面同规则同幂等。"
  @spec set_quote_license_as_person(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def set_quote_license_as_person(person_id, params) do
    with :ok <- validate_quote_spans(person_id, params) do
      case QuoteLicense
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(person_id == ^person_id)
           |> Ash.read_one(authorize?: false) do
        {:ok, nil} ->
          QuoteLicense
          |> Ash.Changeset.for_create(:create, Map.put(params, :person_id, person_id))
          |> Ash.create(authorize?: false)
          |> case do
            {:ok, license} -> {:ok, license_payload(license)}
            {:error, reason} -> {:error, reason}
          end

        {:ok, license} ->
          license
          |> Ash.Changeset.for_update(:update, params)
          |> Ash.update(authorize?: false)
          |> case do
            {:ok, license} -> {:ok, license_payload(license)}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_quote_spans(_person_id, %{chosen_quote_spans: nil}), do: :ok
  defp validate_quote_spans(_person_id, %{chosen_quote_spans: []}), do: :ok

  defp validate_quote_spans(person_id, %{chosen_quote_spans: spans} = params)
       when is_list(spans) and not is_struct(spans),
       do: do_validate_quote_spans(person_id, params)

  defp validate_quote_spans(_person_id, _), do: :ok

  # 金句候选只允许指向本人答案（person + question_key 双因子定位）；U10 第二刀
  # 起 today.now/want/need/say 也是合法宿主（回落 flashback_todays 对应字段文本）。
  # 多句：按宿主分组一次取原文，逐组校验越界（首错即返）。
  defp do_validate_quote_spans(person_id, %{chosen_quote_spans: spans}) do
    spans
    |> Enum.group_by(fn span -> span["question_key"] || span[:question_key] end)
    |> Enum.reduce_while(:ok, fn {qk, group_spans}, :ok ->
      case quote_host_text(person_id, qk) do
        {:ok, text} ->
          case Cgc2046.Flashback.FogSpans.validate(group_spans, text) do
            {:ok, _normalized} ->
              {:cont, :ok}

            {:error, _reason} ->
              {:halt,
               {:error,
                %{
                  code: "flashback_quote_span_out_of_bounds",
                  message: "chosen quote span is out of bounds for the source answer",
                  reason: :quote_span_out_of_bounds
                }}}
          end

        :error ->
          {:halt,
           {:error,
            %{
              code: "flashback_answer_not_found",
              message: "answer not found",
              reason: :answer_not_found
            }}}
      end
    end)
  end

  # ── 注册绑定（R27/KTD7） ─────────────────────────────────────────────

  @doc """
  寄出时刻的一步注册：手机验证码（purpose `:register`）→ find-or-create User
  （`SignInFlow`，与验证码登录同款）→ `person.user_id` 绑定 + token 作废
  （`claimed_by_user_id` 置位，R1 注册即链接作废）→ 签会话 token（httpOnly
  cookie 由 web 层 middleware 交付）。

  绑定成功向记录内原通道（email 有则发）送「档案已绑定」通知（best-effort）。
  """
  @spec register_bind(term(), term(), term(), map()) ::
          {:ok, %{__token__: String.t(), bound: boolean(), masked_phone: String.t() | nil}}
          | {:error, term()}
  def register_bind(token_plaintext, raw_phone, code, context) do
    with {:ok, token} <- fetch_valid(token_plaintext),
         {:ok, phone} <- normalize_phone(raw_phone),
         :ok <- consume_code(phone, code, :register),
         {:ok, user, created?} <- SignInFlow.find_or_create_user(phone),
         :ok <- SignInFlow.maybe_admit_to_default_workspace(user, created?),
         :ok <- SignInFlow.revoke_stored_tokens(user, :web),
         {:ok, user} <- SignInFlow.generate_token(user, :web, context),
         :ok <- bind_person_and_claim(token, user) do
      notify_bound(token.person)

      {:ok,
       %{__token__: user.__metadata__[:token], bound: true, masked_phone: PhoneNumber.mask(phone)}}
    end
  end

  # ── 微信一键收好（R27 小程序路径） ───────────────────────────────────

  @doc """
  微信一键收好（R27 小程序侧）：已登录用户把档案收进账号。

  - **带 token**：绑定该链接的档案并作废链接（同 `register_bind` 的 bind+claim，
    只是身份来自会话而非验证码）；
  - **不带 token**：按**库里已有且已验证的手机/邮箱**自动匹配未认领档案并全部
    绑定（手机已由微信登录验证过，不再二次发码）——「登录后自动匹配 → 直接
    认领」的落点；
  - 幂等：已绑定同一账号 → `bound: true` 且不重复写入；无匹配 → `bound: false`。
  """
  @spec claim_for_user(map() | nil, String.t() | nil) ::
          {:ok,
           %{bound: boolean(), bound_count: non_neg_integer(), masked_phone: String.t() | nil}}
          | {:error, term()}
  def claim_for_user(actor, token_plaintext \\ nil)

  def claim_for_user(%{id: _user_id} = actor, token_plaintext) when is_binary(token_plaintext) do
    with {:ok, token} <- fetch_valid(token_plaintext),
         :ok <- bind_person_and_claim(token, actor) do
      notify_bound(token.person)

      {:ok, %{bound: true, bound_count: 1, masked_phone: mask_phone(token.person.phone)}}
    end
  end

  def claim_for_user(%{id: user_id} = actor, _no_token) do
    persons = matched_persons(actor)

    Enum.each(persons, fn %{id: person_id} ->
      Cgc2046.Flashback.Person
      |> Ash.get!(person_id, authorize?: false)
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:user_id, user_id)
      |> Ash.update!(authorize?: false)
    end)

    case persons do
      [] ->
        {:ok, %{bound: false, bound_count: 0, masked_phone: nil}}

      [%{phone: phone} | _] ->
        {:ok, %{bound: true, bound_count: length(persons), masked_phone: mask_phone(phone)}}
    end
  end

  def claim_for_user(_actor, _token) do
    {:error,
     %{
       code: "flashback_auth_required",
       message: "authentication required",
       reason: :auth_required
     }}
  end

  # 未认领（user_id 空）且手机/邮箱命中登录用户者——not_selected 也认领
  # （圆梦线同样有档案，只是不进名册）。
  defp matched_persons(%{id: _user_id} = actor) do
    import Ecto.Query

    # 逐个字段按需拼条件（Ecto 禁止 `col == ^nil` 这种不安全比较）；
    # email 在 Ash 里是 CiString，进裸 SQL 前转普通 binary
    matches =
      [
        Map.get(actor, :phone) && to_string(Map.get(actor, :phone)),
        Map.get(actor, :email) && to_string(Map.get(actor, :email))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn value ->
        dynamic([p], p.phone == ^value or p.email == ^value)
      end)

    case matches do
      [] ->
        []

      [single] ->
        query_matched(single)

      many ->
        query_matched(Enum.reduce(many, &dynamic([p], ^&1 or ^&2)))
    end
  end

  defp query_matched(condition) do
    import Ecto.Query

    from(p in "flashback_people",
      where: is_nil(p.user_id) and is_nil(p.deleted_at),
      where: ^condition,
      select: %{id: fragment("?::text", p.id), phone: p.phone}
    )
    |> Cgc2046.Repo.all()
  end

  defp mask_phone(phone) when is_binary(phone), do: Cgc2046.Accounts.PhoneNumber.mask(phone)
  defp mask_phone(_), do: nil

  # ── 联系方式更新（R17/KTD7 防劫持） ──────────────────────────────────

  @doc """
  更新手机号：新通道必须先验证（复用 `:change_phone` 用途发码校验），验证
  通过才落库；随后向记录内**原**通道发「联系方式已变更」通知（best-effort，
  失败不影响变更）。回显只给掩码。
  """
  @spec update_contact(term(), term(), term()) :: {:ok, map()} | {:error, term()}
  def update_contact(token_plaintext, raw_phone, code) do
    with {:ok, token} <- fetch_valid(token_plaintext),
         {:ok, phone} <- normalize_phone(raw_phone),
         :ok <- consume_code(phone, code, :change_phone) do
      person = reload_person(token.person_id)

      if person.phone == phone do
        {:ok, %{masked_phone: PhoneNumber.mask(phone), updated: false}}
      else
        {:ok, _} =
          person
          |> Ash.Changeset.for_update(:update, %{})
          |> Ash.Changeset.force_change_attribute(:phone, phone)
          |> Ash.update(authorize?: false)

        notify_contact_changed(person, phone)
        {:ok, %{masked_phone: PhoneNumber.mask(phone), updated: true}}
      end
    end
  end

  # ── 桌面散照候选（R5 数据驱动，批次二散照交互迭代） ──────────────────

  @scatter_max_others 4
  # 桌面散照候选：**本人那张** + 其他场次各一人（attended、未删除），含本人
  # 至多 5 张。每张带「年份 · 城市」线索标签（前端在放大时显影——放大 =
  # 拿到帮助答题的线索）与主人姓氏（姓氏级脱敏由前端渲染）。
  #
  # 确定性：候选按场次时间升序，整列按本人 id 哈希旋转——同一人每次进入摆位
  # 相同（渲染不跳位），不同人摆位不同（「认出自己」不是固定第一张）。
  #
  # 暴露面：与场次页名册同级（token 持有者 = 参与者）；不含手机/邮箱/明文姓名。
  defp scatter_payload(person) do
    mine = %{
      photo_key: person.id,
      label: scatter_label(person.archive_event),
      date_stamp: date_stamp(person.archive_event),
      is_mine: true,
      surname: person.surname
    }

    others =
      other_archives(person.archive_event_id)
      |> Enum.map(fn archive ->
        case first_attended(archive.id) do
          nil ->
            nil

          other ->
            %{
              photo_key: other.id,
              label: scatter_label(archive),
              date_stamp: date_stamp(archive),
              is_mine: false,
              surname: other.surname
            }
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@scatter_max_others)

    entries = [mine | others]
    %{entries: rotate_by_id(entries, person.id)}
  end

  defp scatter_label(archive) do
    "#{archive.occurred_on.year} · #{archive.city}"
  end

  # 拍立得日期戳（批次二收尾）：「2016 10 15」——只给日期不给城市，答题的
  # 线索经一小步认知参与（对照 sheet 场次全名）才成立，谜不泄底。
  defp date_stamp(archive) do
    archive.occurred_on |> Date.to_iso8601() |> String.replace("-", " ")
  end

  defp other_archives(archive_event_id) do
    Cgc2046.Flashback.EventArchive
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id != ^archive_event_id)
    |> Ash.Query.sort(occurred_on: :asc)
    |> Ash.Query.limit(@scatter_max_others)
    |> Ash.read!(authorize?: false)
  end

  # 确定性取人：id 升序首个（同一场反复进入拿到同一张「别人的照片」）
  defp first_attended(archive_event_id) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      archive_event_id == ^archive_event_id and participation == :attended and is_nil(deleted_at)
    )
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  # 同一人恒同一摆位：id 哈希取模旋转（无随机——重进不跳位，测试可断言）
  defp rotate_by_id(entries, person_id) do
    count = length(entries)
    offset = rem(:crypto.hash(:md5, person_id) |> :binary.decode_unsigned(), count)
    {front, rest} = Enum.split(entries, offset)
    Enum.concat(rest, front)
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp line_for(%Person{participation: :attended}), do: "memory"
  defp line_for(%Person{participation: :not_selected}), do: "dream"

  defp profile_payload(person) do
    %{
      full_name: person.full_name,
      surname: person.surname,
      city: person.city,
      occupation_then: person.occupation_then,
      gender: person.gender,
      role: Atom.to_string(person.role),
      participation: Atom.to_string(person.participation),
      applied_at: person.applied_at && DateTime.to_iso8601(person.applied_at),
      archive:
        person.archive_event &&
          %{
            key: person.archive_event.key,
            name: person.archive_event.name,
            city: person.archive_event.city,
            occurred_on:
              person.archive_event.occurred_on &&
                Date.to_iso8601(person.archive_event.occurred_on)
          },
      answers:
        Enum.map(person.answers, fn answer ->
          %{
            id: answer.id,
            question_key: answer.question_key,
            raw_text: answer.raw_text,
            fog_spans: Enum.map(answer.fog_spans || [], &span_payload/1)
          }
        end)
    }
  end

  defp progress_payload(person) do
    %{
      today: today_payload(person.today),
      quote_level:
        if(person.quote_license, do: Atom.to_string(person.quote_license.level), else: "off"),
      masked_phone: PhoneNumber.mask(person.phone),
      masked_email: mask_email(person.email)
    }
  end

  defp today_payload(nil), do: nil

  defp today_payload(today) do
    %{
      now_status: today.now_status,
      want: today.want,
      need: today.need,
      say: today.say,
      want_give_tags: today.want_give_tags,
      mobilization: today.mobilization,
      newsletter_opt_in: today.newsletter_opt_in,
      reconnect_tags: today.reconnect_tags,
      sent_to_wall_at: today.sent_to_wall_at && DateTime.to_iso8601(today.sent_to_wall_at)
    }
  end

  defp license_payload(license) do
    %{
      level: Atom.to_string(license.level),
      chosen_quote_spans:
        license.chosen_quote_spans && Enum.map(license.chosen_quote_spans, &span_payload/1),
      credited_note: license.credited_note
    }
  end

  # FogSpans/资源层存储为字符串键 map（jsonb 形态）；Absinthe object 字段按
  # 原子键解析，投影层统一转原子键（enter/adjustFog/quoteLicense 三处共用）。
  defp span_payload(%{} = span) do
    %{
      question_key: Map.get(span, "question_key") || Map.get(span, :question_key),
      start: Map.get(span, "start") || Map.get(span, :start),
      len: Map.get(span, "len") || Map.get(span, :len),
      reason: Map.get(span, "reason") || Map.get(span, :reason)
    }
  end

  defp wall_result(person, today) do
    %{
      sent_to_wall_at: today.sent_to_wall_at && DateTime.to_iso8601(today.sent_to_wall_at),
      register_hint: %{
        masked_phone: PhoneNumber.mask(person.phone),
        masked_email: mask_email(person.email)
      }
    }
  end

  defp ensure_today(person_id) do
    case Today
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(person_id == ^person_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Today
        |> Ash.Changeset.for_create(:create, %{person_id: person_id})
        |> Ash.create!(authorize?: false)

      {:ok, today} ->
        today
    end
  end

  defp record_touch(token, event) when event in @touch_events do
    Touch
    |> Ash.Changeset.for_create(:create, %{
      person_id: token.person_id,
      token_id: token.id,
      event: event
    })
    |> Ash.create!(authorize?: false)
  end

  defp reload_person(person_id) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^person_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp bind_person_and_claim(token, user) do
    {:ok, _} =
      token.person
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:user_id, user.id)
      |> Ash.update(authorize?: false)

    {:ok, _} =
      token
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:claimed_by_user_id, user.id)
      |> Ash.Changeset.force_change_attribute(:claimed_at, DateTime.utc_now())
      |> Ash.update(authorize?: false)

    :ok
  end

  defp normalize_phone(raw) do
    case PhoneNumber.normalize(raw) do
      {:ok, phone} ->
        {:ok, phone}

      {:error, :invalid} ->
        {:error,
         %{code: "invalid_phone", message: "Invalid phone number", reason: :invalid_phone}}
    end
  end

  defp consume_code(phone, code, purpose) do
    case PhoneVerificationCode.consume_valid(phone, code, purpose) do
      :ok ->
        :ok

      {:error, _} ->
        # 防枚举：码不存在/过期/错码/耗尽同一句（同 PhoneCodeSignIn）。
        {:error,
         %{
           code: "invalid_or_expired_code",
           message: "Invalid or expired code",
           reason: :invalid_code
         }}
    end
  end

  # 掩码：本地部分首字符 + *** + @域名（确认页回显用，KTD7）。
  defp mask_email(nil), do: nil

  defp mask_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] ->
        head = String.slice(local, 0, 1)
        "#{head}***@#{domain}"

      _ ->
        "***"
    end
  end

  defp mask_email(_), do: nil

  # ── 原通道通知（best-effort：失败只 log，不阻断主流程） ─────────────

  defp notify_bound(person) do
    if is_binary(person.email) and person.email != "" do
      send_notice_email(person.email, "你的闪念间档案已绑定账号", "你当年报名形成的闪念间档案已与你的账号绑定。此后请从「我的」进入查看与编辑。")
    end
  end

  defp notify_contact_changed(person, _new_phone) do
    if is_binary(person.email) and person.email != "" do
      send_notice_email(person.email, "你的闪念间档案联系方式已变更", "你留在闪念间档案的手机号刚刚被更新。如果这不是你本人的操作，请联系我们。")
    end

    # 原手机号的短信通知：SendCloud 单条模板短信通道，未配置时跳过。
    if is_binary(person.phone) and person.phone != "" do
      _ = notify_contact_changed_sms(person.phone)
    end
  end

  defp notify_contact_changed_sms(phone) do
    sms = Application.get_env(:cgc_2046, :sms_sendcloud, [])

    if Cgc2046.Integrations.SendCloud.Sms.configured?() do
      Cgc2046.Integrations.SendCloud.Sms.send_template_sms(
        phone,
        Keyword.fetch!(sms, :template_id),
        %{"content" => "你的闪念间档案联系方式已变更，如非本人操作请联系 CGC 2046"},
        "flashback-contact-change"
      )
    else
      :ok
    end
  end

  defp send_notice_email(to, subject, text_body) do
    config = Application.get_env(:cgc_2046, Cgc2046.Mailer, [])
    from = Keyword.get(config, :from, "no-reply@example.com")
    from_name = Keyword.get(config, :from_name, "CGC 2046")

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from({from_name, from})
      |> Swoosh.Email.to(to)
      |> Swoosh.Email.subject(subject)
      |> Swoosh.Email.text_body(text_body)

    case Mailer.deliver(email) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[flashback] notice email failed: #{inspect(reason)}")
    end
  end
end
