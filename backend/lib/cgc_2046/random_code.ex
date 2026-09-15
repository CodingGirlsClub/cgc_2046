defmodule Cgc2046.RandomCode do
  @moduledoc """
  无偏 6 位数字码共享生成器（KTD5：从 `Cgc2046.Accounts.PhoneVerificationCode`
  抽出——登录验证码与报名核销码共用同一 rejection-sampling 实现）。

  码按字符串处理并保留前导零（`"042424"` 是合法码）。

  ## 测试注入

  `stub_next/1`（仅 test 环境提供）把生成结果钉死为固定值并存进程字典
  （同 `Cgc2046.Payments.Providers.Fake.script!/1` 的进程隔离纪律），供避碰
  耗尽等确定性场景布置；`stub_calls/0` 返回本进程已生成的次数。
  """

  @code_space 1_000_000
  # 3 字节随机数均匀覆盖 [0, 16_777_216)，超出 16×10^6 的尾部丢弃重采
  # （2^24 mod 10^6 ≈ 6% 相对偏差区间外重采样），保证无偏。
  @code_reject_below 16 * @code_space

  if Mix.env() == :test do
    @spec generate() :: String.t()
    def generate do
      case stubbed() do
        nil -> do_generate()
        code -> code
      end
    end
  else
    @spec generate() :: String.t()
    def generate, do: do_generate()
  end

  @spec do_generate() :: String.t()
  defp do_generate do
    n = :binary.decode_unsigned(:crypto.strong_rand_bytes(3))

    if n >= @code_reject_below do
      do_generate()
    else
      n
      |> rem(@code_space)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")
    end
  end

  if Mix.env() == :test do
    @doc "钉死本进程的下一次及后续生成结果（测试布置；值必须本身是 6 位数字串）。"
    @spec stub_next((-> String.t())) :: :ok
    def stub_next(fun) when is_function(fun, 0) do
      Process.put({__MODULE__, :stubbed}, fun)
      :ok
    end

    @doc "本进程经生成器产码的累计次数（断言避碰重试上限用）。"
    @spec stub_calls() :: non_neg_integer()
    def stub_calls, do: Process.get({__MODULE__, :calls}, 0)

    @spec stubbed() :: String.t() | nil
    defp stubbed do
      Process.put({__MODULE__, :calls}, stub_calls() + 1)

      case Process.get({__MODULE__, :stubbed}) do
        nil -> nil
        fun -> fun.()
      end
    end
  end
end
