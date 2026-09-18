defmodule Mix.Tasks.Flashback.SeedDemo do
  @moduledoc """
  多场次演示数据（追加式、幂等，散照/长廊多场迭代用）。

  - 新增三场：2012-02-26 上海首场、2016-10-15 广州、2018-04-21 深圳；
  - 每场 8-12 人（attended 为主，每场 1 名 not_selected 供圆梦线演练），
    全部为**虚构合成**姓名/职业/两题答案（self_intro + funny_thing），
    部分人带句子级雾面（对齐真实导入形态）；
  - 每场 1-2 人已寄出（Today + QuoteLicense anonymous）——长廊/场次页有
    显影卡、金句墙有候选句；
  - 每场为 1 名 attended 未寄出者铸 token：明文只进 stdout（KTD2，不落库）。

  幂等（追加语义）：EventArchive 按 key get-or-create；Person 按
  （archive, full_name）查重，已存在整场/整人跳过——北京 344 人、既有
  金句与 token 完全不动，重跑零新增。

  ## 用法

      mix flashback.seed_demo            # dry-run：打印计划，不写库
      mix flashback.seed_demo --commit   # 真跑（token 链接只在 --commit 时输出）
  """

  @shortdoc "Seed 多场次演示数据（追加式幂等）"

  use Mix.Task

  alias Cgc2046.Accounts.TokenCredential
  alias Cgc2046.Flashback
  alias Cgc2046.Flashback.{Answer, Person, QuoteLicense, Token, Today}

  require Ash.Query

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    commit? = "--commit" in args

    if commit? do
      backfill_known_counts()
    end

    Enum.each(archives(), fn spec ->
      archive = ensure_archive(spec, commit?)
      existing = existing_names(archive)

      # 查重用 Map.has_key?（`in` 对 map 恒不命中会重复插入）
      new_people =
        Enum.filter(spec.people, fn person -> not Map.has_key?(existing, person.full_name) end)

      Mix.shell().info(
        "场次 #{archive.key}（#{archive.name}）：已有 #{map_size(existing)} 人，" <>
          "本次新增 #{length(new_people)} 人#{if commit?, do: "", else: "（dry-run，不写库）"}"
      )

      if commit? do
        inserted = Enum.map(new_people, fn person -> insert_person(archive, person) end)

        # 每场铸 1 个 token：数据表里 token_for: true 的 attended 未寄出者
        case Enum.find(inserted, &Map.get(&1, :token_for)) do
          nil -> :ok
          token_person -> mint_token!(token_person.row_id)
        end
      end
    end)

    if commit? do
      Mix.shell().info("完成。")
    else
      Mix.shell().info("dry-run 结束：加 --commit 真跑。")
    end
  end

  # ── 数据表（全部虚构；token_for = 本场铸链接的人，须 attended 未寄出） ──

  defp archives do
    [
      %{
        key: "2012-02-26-sh",
        name: "Rails Girls Shanghai",
        city: "上海",
        occurred_on: ~D[2012-02-26],
        token_for: "沈知一",
        people: shanghai()
      },
      %{
        key: "2016-10-15-gz",
        name: "Girls Coding Day Guangzhou",
        city: "广州",
        occurred_on: ~D[2016-10-15],
        token_for: "麦穗宁",
        people: guangzhou()
      },
      %{
        key: "2018-04-21-sz",
        name: "Girls Coding Day Shenzhen",
        city: "深圳",
        occurred_on: ~D[2018-04-21],
        token_for: "蒲晓棠",
        people: shenzhen()
      }
    ]
  end

  # 上海首场：12 人（11 attended + 1 not_selected），2 人已寄出
  defp shanghai do
    [
      %{
        full_name: "沈知一",
        surname: "沈",
        gender: "女",
        occupation: "出版社校对",
        token_for: true,
        answers: %{
          "self_intro" => "刚毕业的文科生，在出版社做校对。每天路过徐家汇的写字楼，会想里面的人在做什么。",
          "funny_thing" => "25 岁生日给自己买了台二手 ThinkPad，在麦当劳连了三小时 Wi-Fi，教会自己打出 Hello World。"
        }
      },
      %{
        full_name: "阮清梧",
        surname: "阮",
        gender: "女",
        occupation: "日语翻译",
        sent: %{
          now_status: "还在翻译，只是翻的东西从合同变成了技术文档。",
          want: "想看懂老公写的代码，顺便自己做一个记录菜谱的小程序。",
          say: "谢谢那天的柠檬蛋糕，我到现在还记得。",
          quote_len: 14
        },
        answers: %{
          "self_intro" => "自由译者，主要接日语合同。第一次来徐家汇，被写字楼的电梯吓到了。",
          "funny_thing" => "报名的动机是想知道「编译」和「翻译」到底差在哪里。"
        }
      },
      %{
        full_name: "翟雨眠",
        surname: "翟",
        gender: "女",
        occupation: "小学美术老师",
        answers: %{
          "self_intro" => "教小朋友画画。相信做东西和画画一样，都是从一团模糊开始慢慢显影的。",
          "funny_thing" => "把第一行代码打印出来贴在画室墙上，学生以为是新的抽象诗。"
        },
        fog: %{"self_intro" => 7}
      },
      %{
        full_name: "储一苇",
        surname: "储",
        gender: "女",
        occupation: "外贸跟单员",
        answers: %{
          "self_intro" => "在浦东一家外贸公司跟单，每天和传真机打交道，想看看传真机之外的世界。",
          "funny_thing" => "培训当天把笔记本忘在地铁上，借了邻座姐姐的电脑写完了第一个网页。"
        }
      },
      %{
        full_name: "厍冬凌",
        surname: "厍",
        gender: "女",
        occupation: "会计",
        answers: %{
          "self_intro" => "做了三年会计，数字都对得上，就是总觉得生活里少了一行代码。",
          "funny_thing" => "给 Excel 写了人生第一个 if 公式后激动地请同事喝了奶茶。"
        }
      },
      %{
        full_name: "邢茉莉",
        surname: "邢",
        gender: "女",
        occupation: "护士",
        answers: %{
          "self_intro" => "夜班刚下就来上课了。想证明除了打针发药，我还能学会别的。",
          "funny_thing" => "把 CSS 的颜色代码记在值班本上，被护士长以为是新的药品编号。"
        }
      },
      %{
        full_name: "巴念初",
        surname: "巴",
        gender: "女",
        occupation: "研究生在读",
        answers: %{
          "self_intro" => "中文系研二，写论文写到怀疑人生，来试试写代码会不会更治愈。",
          "funny_thing" => "发现代码也有标点错误，瞬间觉得论文的错别字没那么可怕了。"
        }
      },
      %{
        full_name: "屠半夏",
        surname: "屠",
        gender: "女",
        occupation: "花店店主",
        sent: %{
          now_status: "花店还开着，多了个线上下单的小网站，我自己改的。",
          want: "给店里做一个「今天到店的花」推送，每天自动发。",
          say: "寄出这张卡的时候，店里正香得像 2012 年那个春天。",
          quote_len: 16
        },
        answers: %{
          "self_intro" => "开花店的，第三年。想给花店做个网站，觉得应该先懂一点代码。",
          "funny_thing" => "把店铺 WiFi 密码设置成了 ruby2012，客人连上了都以为很浪漫。"
        },
        fog: %{"funny_thing" => 10}
      },
      %{
        full_name: "门望舒",
        surname: "门",
        gender: "女",
        occupation: "人事专员",
        answers: %{
          "self_intro" => "做人事的，天天帮别人做职业规划，轮到自己却想换个活法。",
          "funny_thing" => "面试完别人，跑来面试自己：你为什么想学编程？答不上来，就来学了。"
        }
      },
      %{
        full_name: "竺小满",
        surname: "竺",
        gender: "女",
        occupation: "博物馆讲解员",
        answers: %{
          "self_intro" => "在博物馆讲文物故事。想学会做一个小程序，把故事讲到手机里。",
          "funny_thing" => "第一次运行成功时脱口而出「开机」，被教练笑了整整一个下午。"
        }
      },
      %{
        full_name: "终南絮",
        surname: "终",
        gender: "女",
        occupation: "咖啡师",
        answers: %{
          "self_intro" => "拉花三年，最近觉得咖啡和代码一样，都是精确的艺术。",
          "funny_thing" => "用拿铁在桌上拉了一个分号，说这是「还没写完的话」。"
        },
        fog: %{"self_intro" => 6}
      },
      %{
        full_name: "逄星野",
        surname: "逄",
        gender: "女",
        occupation: "自由撰稿人",
        participation: :not_selected,
        answers: %{
          "self_intro" => "给杂志写科技报道，写了很多年别人的故事。",
          "funny_thing" => "落选那天把报名表打印出来夹在笔记本里，想着下次一定要进教室。"
        }
      }
    ]
  end

  # 广州场：10 人（9 attended + 1 not_selected），1 人已寄出
  defp guangzhou do
    [
      %{
        full_name: "麦穗宁",
        surname: "麦",
        gender: "女",
        occupation: "茶楼点心师",
        token_for: true,
        answers: %{
          "self_intro" => "凌晨三点起褶虾饺的点心师。想知道代码是不是也讲究「皮薄馅靓」。",
          "funny_thing" => "把第一个程序命名为虾饺.exe，因为它们都讲究一个严丝合缝。"
        }
      },
      %{
        full_name: "关雎尔",
        surname: "关",
        gender: "女",
        occupation: "海关报关员",
        answers: %{
          "self_intro" => "报关八年，见惯了各种「进出口」，想来进出口一下自己的脑子。",
          "funny_thing" => "给变量起名全都用报关术语，coach 看到 ShippingFee 时愣了三秒。"
        },
        fog: %{"self_intro" => 8}
      },
      %{
        full_name: "廖晚晴",
        surname: "廖",
        gender: "女",
        occupation: "幼师",
        sent: %{
          now_status: "还是带小朋友，但已经会用 scratch 教他们做小游戏了。",
          want: "做一个班级打卡小程序，家长再也不用接龙了。",
          say: "当年教我的教练，我现在把这份耐心传给了四岁的小朋友。",
          quote_len: 12
        },
        answers: %{
          "self_intro" => "幼儿园老师，会讲一百个故事，想学会做一个讲故事的小程序。",
          "funny_thing" => "把代码念给小朋友听，他们说这是「机器人学说话」。"
        }
      },
      %{
        full_name: "岑知夏",
        surname: "岑",
        gender: "女",
        occupation: " Pharmacy 药师",
        answers: %{
          "self_intro" => "药房药师，每天核对处方，觉得代码和处方一样错一个字都不行。",
          "funny_thing" => "把报错信息抄在处方笺背面带回家研究，被家人以为在写密码。"
        }
      },
      %{
        full_name: "盛白露",
        surname: "盛",
        gender: "女",
        occupation: "电台主播",
        answers: %{
          "self_intro" => "晚间节目主播。声音认识我的人多，想做一个没人知道是我做的应用。",
          "funny_thing" => "在节目里念了自己的第一行代码，听众留言说像在念情诗。"
        },
        fog: %{"funny_thing" => 9}
      },
      %{
        full_name: "饶竹里",
        surname: "饶",
        gender: "女",
        occupation: "会计事务所审计",
        answers: %{
          "self_intro" => "审计季每天对到凌晨，想学一个能帮我对账的本事。",
          "funny_thing" => "第一次跑通循环时激动得把底稿列了三遍「1+1=2」。"
        }
      },
      %{
        full_name: "闵知微",
        surname: "闵",
        gender: "女",
        occupation: "服装店主",
        answers: %{
          "self_intro" => "在十三行做服装批发，想搞明白网上的店是怎么把货卖出去的。",
          "funny_thing" => "给自己的店起英文名用了第一个学会的单词：Variable，变量女装。"
        }
      },
      %{
        full_name: "应长风",
        surname: "应",
        gender: "女",
        occupation: "健身教练",
        answers: %{
          "self_intro" => "带课六年的健身教练。肌肉记忆学会了，想来学学代码记忆。",
          "funny_thing" => "把 while 循环比作深蹲组数讲给学员听，全组居然都懂了。"
        }
      },
      %{
        full_name: "汲云溪",
        surname: "汲",
        gender: "女",
        occupation: "客服主管",
        answers: %{
          "self_intro" => "带十个人的客服团队，每天听「系统又坏了」，想亲自看看系统怎么坏。",
          "funny_thing" => "给工单分类写了第一个正则，从此看什么都想匹配一下。"
        },
        fog: %{"self_intro" => 5}
      },
      %{
        full_name: "蔺晚舟",
        surname: "蔺",
        gender: "女",
        occupation: "导游",
        participation: :not_selected,
        answers: %{
          "self_intro" => "带团走过二十几个国家，唯独没进过机房。",
          "funny_thing" => "落选后自己买了本入门书，在带团大巴上背变量命名规则。"
        }
      }
    ]
  end

  # 深圳场：9 人（8 attended + 1 not_selected），1 人已寄出
  defp shenzhen do
    [
      %{
        full_name: "蒲晓棠",
        surname: "蒲",
        gender: "女",
        occupation: "外贸业务员",
        token_for: true,
        answers: %{
          "self_intro" => "在华强北做了五年外贸，看着一格格电子元件变成产品，想亲手写一个出来。",
          "funny_thing" => "在华强北买零件组装了自己第一台「写代码专用机」，成本六百块。"
        }
      },
      %{
        full_name: "湛书瑶",
        surname: "湛",
        gender: "女",
        occupation: "平面设计师",
        answers: %{
          "self_intro" => "设计做了七年，被程序员说「这个效果实现不了」七百次，决定自己实现。",
          "funny_thing" => "给按钮悬停效果写 CSS 时激动得截图发给整个设计部。"
        },
        fog: %{"self_intro" => 9}
      },
      %{
        full_name: "费星阑",
        surname: "费",
        gender: "女",
        occupation: "进出口质检",
        sent: %{
          now_status: "还在质检，不过现在质检的是自己的代码。",
          want: "写一个验货清单小程序，让同事不用再翻纸质表格。",
          say: "写代码和验货一样，都相信细节里藏着一切。",
          quote_len: 15
        },
        answers: %{
          "self_intro" => "电子厂质检员，看电路板看了五年，想知道驱动它们的那一行行字长什么样。",
          "funny_thing" => "把 Hello World 打印出来贴在质检章旁边，说这是自己的「出厂设置」。"
        }
      },
      %{
        full_name: "简亦繁",
        surname: "简",
        gender: "女",
        occupation: "英语家教",
        answers: %{
          "self_intro" => "教了五年英语，学生问我会不会编程，我说不会——然后就来这里了。",
          "funny_thing" => "发现编程术语全是英语缩写，瞬间觉得自信回来了。"
        }
      },
      %{
        full_name: "鱼念安",
        surname: "鱼",
        gender: "女",
        occupation: "宠物医生",
        answers: %{
          "self_intro" => "宠物医院医生，想做一个提醒主人打疫苗的小程序，顺便学门手艺。",
          "funny_thing" => "给测试数据起名字全用病号猫的名字，coach 以为我在开猫咖。"
        }
      },
      %{
        full_name: "艾青梧",
        surname: "艾",
        gender: "女",
        occupation: "供应链专员",
        answers: %{
          "self_intro" => "深圳供应链公司做计划员，Excel 表格大师，想知道表格之外的世界。",
          "funny_thing" => "把 vlookup 和 for each 做成对照表，感觉自己掌握了双语。"
        },
        fog: %{"funny_thing" => 7}
      },
      %{
        full_name: "庾静好",
        surname: "庾",
        gender: "女",
        occupation: "烘焙工作室主理人",
        answers: %{
          "self_intro" => "开烘焙工作室，配方精确到克，想试试精确到字符是什么感觉。",
          "funny_thing" => "发现调试代码和调蛋糕配方一样，失败品自己吃掉就好。"
        }
      },
      %{
        full_name: "柏南乔",
        surname: "柏",
        gender: "女",
        occupation: "物业管家",
        answers: %{
          "self_intro" => "物业管理处管家，业主群消息每天八百条，想写个机器人替我回。",
          "funny_thing" => "第一次知道「机器人」是要自己写的时候，沉默了十分钟然后继续上课。"
        }
      },
      %{
        full_name: "蓟云岫",
        surname: "蓟",
        gender: "女",
        occupation: "电商运营",
        participation: :not_selected,
        answers: %{
          "self_intro" => "做电商运营，天天和数据打交道，从没亲手写过一行代码。",
          "funny_thing" => "落选后把详情页的代码研究了个遍，现在给设计师提需求都带行号。"
        }
      }
    ]
  end

  # ── 落库（幂等追加；照 Import 的 authorize?: false 内部路径） ──────────

  # dry-run 只查不写：缺失场次打印计划并返回 spec（后续插入不会发生）
  defp ensure_archive(spec, commit?)

  defp ensure_archive(spec, false) do
    case get_archive(spec.key) do
      {:ok, nil} ->
        Mix.shell().info("  （dry-run）将新建场次 #{spec.key}")
        spec

      {:ok, archive} ->
        archive
    end
  end

  defp ensure_archive(spec, true) do
    case get_archive(spec.key) do
      {:ok, nil} ->
        Mix.shell().info("  新建场次 #{spec.key}")

        Flashback.EventArchive
        |> Ash.Changeset.for_create(:create, %{
          key: spec.key,
          name: spec.name,
          city: spec.city,
          occurred_on: spec.occurred_on,
          applied_count: length(spec.people),
          attended_count: Enum.count(spec.people, &(&1[:participation] != :not_selected))
        })
        |> Ash.create!(authorize?: false)

      {:ok, archive} ->
        archive
    end
  end

  defp get_archive(key) do
    Flashback.EventArchive
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key)
    |> Ash.read_one(authorize?: false)
  end

  defp existing_names(archive) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(archive_event_id == ^archive.id)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.full_name, true})
  end

  defp insert_person(archive, person) do
    participation = Map.get(person, :participation, :attended)

    row =
      Flashback.Person
      |> Ash.Changeset.for_create(:create, %{
        archive_event_id: archive.id,
        full_name: person.full_name,
        surname: person.surname,
        gender: person.gender,
        city: archive.city,
        occupation_then: person.occupation,
        role: :learner,
        participation: participation,
        # 手机/邮箱为虚构合成段（137 0002xxxx / example.com），仅承接找回与触达字段形态
        phone: fake_phone(person.full_name),
        email: fake_email(person.full_name),
        applied_at: applied_at(archive.occurred_on, person.full_name)
      })
      |> Ash.create!(authorize?: false)

    Enum.each(person.answers, fn {question_key, raw_text} ->
      Answer
      |> Ash.Changeset.for_create(:create, %{
        person_id: row.id,
        question_key: question_key,
        raw_text: raw_text,
        fog_spans: fog_spans(person, question_key)
      })
      |> Ash.create!(authorize?: false)
    end)

    if sent = Map.get(person, :sent) do
      today =
        Today
        |> Ash.Changeset.for_create(:create, %{
          person_id: row.id,
          now_status: sent.now_status,
          want: sent.want,
          say: sent.say
        })
        |> Ash.create!(authorize?: false)

      # create action 不收 sent_to_wall_at（寄出走 update 面）；seed 同 token 面
      # send_to_wall 的 update 写法置位
      today
      |> Ash.Changeset.for_update(:update, %{sent_to_wall_at: wall_at(archive.occurred_on)})
      |> Ash.update!(authorize?: false)

      QuoteLicense
      |> Ash.Changeset.for_create(:create, %{
        person_id: row.id,
        level: :anonymous,
        question_key: "self_intro",
        chosen_quote_span: %{"start" => 0, "len" => sent.quote_len}
      })
      |> Ash.create!(authorize?: false)
    end

    if Map.get(person, :token_for) do
      Mix.shell().info("    （#{person.full_name} 标记为 token 人）")
    end

    Map.put(person, :row_id, row.id)
  end

  defp mint_token!(person_id) do
    plaintext = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    {:ok, hash} = TokenCredential.hash(plaintext)

    Token
    |> Ash.Changeset.for_create(:create, %{person_id: person_id, token_hash: hash})
    |> Ash.create!(authorize?: false)

    Mix.shell().info("")
    Mix.shell().info("  → 首程链接（明文只出现在这里，不落库）：")
    Mix.shell().info("    http://localhost:3050/flashback/enter?token=#{plaintext}")
    Mix.shell().info("")
  end

  # 既有场次计数补齐（幂等）：早期导入未带 applied/attended（public 统计层显 0）。
  # 仅在列为空时写，不覆盖人工修正值。
  @count_patches %{
    "2014-01-11-bj" => {344, 102}
  }

  defp backfill_known_counts do
    Enum.each(@count_patches, fn {key, {applied, attended}} ->
      case get_archive(key) do
        {:ok, %{} = archive} ->
          # EventArchive 无 update action（只读资源）——运维补数直走 Repo
          if is_nil(archive.applied_count) or is_nil(archive.attended_count) do
            import Ecto.Query

            {n, _} =
              Cgc2046.Repo.update_all(
                from(a in "flashback_event_archives",
                  where: a.key == ^key,
                  update: [set: [applied_count: ^applied, attended_count: ^attended]]
                ),
                []
              )

            if n > 0 do
              Mix.shell().info("  补齐 #{key} 计数：报名 #{applied} / 走进教室 #{attended}")
            end
          end

        _ ->
          :ok
      end
    end)
  end

  # 按（archive, full_name）确定性派生假 PII——真实联系方式永不进仓
  defp fake_phone(full_name) do
    n =
      full_name
      |> then(&:crypto.hash(:md5, &1))
      |> :binary.decode_unsigned()
      |> rem(10_000)

    "+861370002#{String.pad_leading(Integer.to_string(n), 4, "0")}"
  end

  defp fake_email(full_name) do
    n = :crypto.hash(:md5, full_name) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    "#{n}@example.com"
  end

  # 报名时间戳 = 场次日当天，按姓名确定性给一个钟点（R3 相对年数锚点）
  defp applied_at(occurred_on, full_name) do
    minutes = rem(:crypto.hash(:md5, full_name) |> :binary.decode_unsigned(), 600)
    base = DateTime.new!(occurred_on, ~T[08:00:00], "Etc/UTC")
    DateTime.add(base, minutes * 60)
  end

  defp wall_at(occurred_on) do
    DateTime.new!(Date.add(occurred_on, 14), ~T[12:00:00], "Etc/UTC")
  end

  defp fog_spans(person, question_key) do
    case Map.get(person, :fog) do
      %{^question_key => len} -> [%{"start" => 0, "len" => len, "reason" => "owner"}]
      _ -> []
    end
  end
end
