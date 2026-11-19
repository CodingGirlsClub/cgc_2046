defmodule Cgc2046.LlmGateway.LeaseManager do
  @moduledoc """
  单用户并发 SSE 流租约（GenServer 持有计数 + 进程监控）。

  与 `Registry` 的 count-then-register 方案不同，`acquire_slot/2` 在单个
  GenServer 调用内完成「检查 + 计数 + 监控」，并发请求不会越过上限；调用
  进程退出/崩溃时 `:DOWN` 自动释放该进程持有的全部槽位。
  """

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  为调用进程获取一个并发流槽位。返回 `:ok` 或
  `{:error, :too_many_concurrent_streams}`。
  """
  def acquire_slot(user_id, max_concurrent_streams \\ 3)
      when is_binary(user_id) and is_integer(max_concurrent_streams) and
             max_concurrent_streams > 0 do
    GenServer.call(__MODULE__, {:acquire, user_id, max_concurrent_streams})
  end

  @doc """
  释放调用进程在 `user_id` 下的全部槽位（幂等）。
  """
  def release_slot(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:release_all, user_id})
    :ok
  end

  @doc """
  当前用户活动流数量。
  """
  def active_streams_count(user_id) when is_binary(user_id) do
    GenServer.call(__MODULE__, {:count, user_id})
  end

  @impl true
  def init(_state), do: {:ok, %{}}

  @impl true
  def handle_call({:acquire, user_id, max_concurrent_streams}, {pid, _from}, state) do
    entry = Map.get(state, user_id, %{count: 0, holders: %{}})

    if entry.count >= max_concurrent_streams do
      {:reply, {:error, :too_many_concurrent_streams}, state}
    else
      case Map.get(entry.holders, pid) do
        nil ->
          ref = Process.monitor(pid)

          new_entry = %{
            entry
            | count: entry.count + 1,
              holders: Map.put(entry.holders, pid, %{ref: ref, count: 1})
          }

          {:reply, :ok, Map.put(state, user_id, new_entry)}

        holder ->
          new_entry = %{
            entry
            | count: entry.count + 1,
              holders: Map.put(entry.holders, pid, %{holder | count: holder.count + 1})
          }

          {:reply, :ok, Map.put(state, user_id, new_entry)}
      end
    end
  end

  def handle_call({:release_all, user_id}, {pid, _from}, state) do
    {:reply, :ok, drop_holder(state, user_id, pid)}
  end

  def handle_call({:count, user_id}, _from, state) do
    count = state |> Map.get(user_id, %{}) |> Map.get(:count, 0)
    {:reply, count, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      Enum.reduce(state, state, fn {user_id, entry}, acc ->
        case Map.get(entry.holders, pid) do
          %{ref: ^ref} -> drop_holder(acc, user_id, pid)
          _ -> acc
        end
      end)

    {:noreply, state}
  end

  defp drop_holder(state, user_id, pid) do
    case Map.get(state, user_id) do
      nil ->
        state

      entry ->
        case Map.pop(entry.holders, pid) do
          {nil, _holders} ->
            state

          {holder, holders} ->
            Process.demonitor(holder.ref, [:flush])
            remaining = entry.count - holder.count

            if remaining <= 0 do
              Map.delete(state, user_id)
            else
              Map.put(state, user_id, %{entry | count: remaining, holders: holders})
            end
        end
    end
  end
end
