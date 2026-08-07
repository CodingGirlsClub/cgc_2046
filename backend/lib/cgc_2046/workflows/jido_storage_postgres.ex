defmodule Cgc2046.Workflows.JidoStoragePostgres do
  @moduledoc """
  Jido.Storage Postgres 适配器（阶段 4 #37，替 ETS）。

  `Jido.Storage` behavior 的 6 个 callback 全实现。checkpoint 与 thread 数据用
  `:erlang.term_to_binary/1` 编码存 `bytea` 列：

  - `jido_checkpoints`：key（term_to_binary 的 checkpoint key）+ data（term_to_binary 的
    checkpoint map）
  - `jido_thread_entries`：thread 条目（term_to_binary 的 `Jido.Thread.Entry`），
    `thread_id + seq` 复合主键
  - `jido_thread_meta`：thread 元数据 + 乐观并发 rev

  序列化安全：workflow struct 含匿名闭包（`Step.new(work: fn ...)` 等，非 external
  function），JSON 无法编码；但同 BEAM 内 `term_to_binary`/`binary_to_term` round-trip
  安全（闭包编码为对其定义模块的引用，模块已加载）。单节点 Phoenix 部署满足此条件。

  `append_thread/3` 的 `:expected_rev` 乐观并发在 DB 事务内校验 meta.rev，
  冲突返回 `{:error, :conflict}`（对应 `Jido.Persist.flush_journal` 的并发路径）。

  opts 接受 `repo:`（默认 `Cgc2046.Repo`，测试可传 sandbox repo）。
  """

  @behaviour Jido.Storage

  import Ecto.Query

  alias Jido.Thread
  alias Jido.Thread.Entry
  alias Jido.Thread.EntryNormalizer

  @default_repo Cgc2046.Repo

  @impl true
  @spec get_checkpoint(term(), keyword()) :: {:ok, term()} | :not_found | {:error, term()}
  def get_checkpoint(key, opts) do
    repo = repo(opts)
    key_bytea = :erlang.term_to_binary(key)

    case repo.one(
           from(c in "jido_checkpoints",
             where: c.key_bytea == ^key_bytea,
             select: c.data_bytea
           )
         ) do
      nil -> :not_found
      data_bytea -> {:ok, :erlang.binary_to_term(data_bytea)}
    end
  rescue
    e -> {:error, {:storage_error, Exception.message(e)}}
  end

  @impl true
  @spec put_checkpoint(term(), term(), keyword()) :: :ok | {:error, term()}
  def put_checkpoint(key, data, opts) do
    repo = repo(opts)
    key_bytea = :erlang.term_to_binary(key)
    data_bytea = :erlang.term_to_binary(data)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

    repo.query!(
      """
      INSERT INTO jido_checkpoints (key_bytea, data_bytea, inserted_at, updated_at)
      VALUES ($1, $2, $3, $3)
      ON CONFLICT (key_bytea) DO UPDATE SET data_bytea = EXCLUDED.data_bytea, updated_at = EXCLUDED.updated_at
      """,
      [key_bytea, data_bytea, now]
    )

    :ok
  rescue
    e -> {:error, {:storage_error, Exception.message(e)}}
  end

  @impl true
  @spec delete_checkpoint(term(), keyword()) :: :ok | {:error, term()}
  def delete_checkpoint(key, opts) do
    repo = repo(opts)
    key_bytea = :erlang.term_to_binary(key)

    repo.query!("DELETE FROM jido_checkpoints WHERE key_bytea = $1", [key_bytea])
    :ok
  rescue
    e -> {:error, {:storage_error, Exception.message(e)}}
  end

  @impl true
  @spec load_thread(String.t(), keyword()) :: {:ok, Thread.t()} | :not_found | {:error, term()}
  def load_thread(thread_id, opts) do
    repo = repo(opts)

    entries =
      repo.all(
        from(e in "jido_thread_entries",
          where: e.thread_id == ^thread_id,
          order_by: e.seq,
          select: e.entry_bytea
        )
      )
      |> Enum.map(&:erlang.binary_to_term/1)

    case entries do
      [] ->
        :not_found

      entries ->
        meta = fetch_thread_meta(repo, thread_id)
        {:ok, reconstruct_thread(thread_id, entries, meta)}
    end
  rescue
    e -> {:error, {:storage_error, Exception.message(e)}}
  end

  @impl true
  @spec append_thread(String.t(), [Entry.t()], keyword()) ::
          {:ok, Thread.t()} | {:error, term()}
  def append_thread(thread_id, entries, opts) do
    repo = repo(opts)
    expected_rev = Keyword.get(opts, :expected_rev)
    now = System.system_time(:millisecond)

    repo.transaction(fn ->
      with :ok <- check_expected_rev(repo, thread_id, expected_rev) do
        current_rev = fetch_thread_rev(repo, thread_id)

        prepared_entries =
          EntryNormalizer.normalize_many(entries, current_rev, now)

        insert_entries(repo, thread_id, prepared_entries, now)
        upsert_thread_meta(repo, thread_id, prepared_entries, now, opts)

        # 重建完整 thread（entries + meta）
        all_entries =
          repo.all(
            from(e in "jido_thread_entries",
              where: e.thread_id == ^thread_id,
              order_by: e.seq,
              select: e.entry_bytea
            )
          )
          |> Enum.map(&:erlang.binary_to_term/1)

        meta = fetch_thread_meta(repo, thread_id)
        {:ok, reconstruct_thread(thread_id, all_entries, meta)}
      end
    end)
    |> case do
      {:ok, {:ok, thread}} -> {:ok, thread}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, %Ecto.ConstraintError{}} -> {:error, :conflict}
      {:error, reason} -> {:error, {:storage_error, inspect(reason)}}
    end
  rescue
    e -> {:error, {:storage_error, Exception.message(e)}}
  end

  @impl true
  @spec delete_thread(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_thread(thread_id, opts) do
    repo = repo(opts)

    repo.query!("DELETE FROM jido_thread_entries WHERE thread_id = $1", [thread_id])
    repo.query!("DELETE FROM jido_thread_meta WHERE thread_id = $1", [thread_id])
    :ok
  rescue
    e -> {:error, {:storage_error, Exception.message(e)}}
  end

  # --- 私有实现 -------------------------------------------------------------

  defp repo(opts) do
    Keyword.get(opts, :repo, @default_repo)
  end

  defp check_expected_rev(_repo, _thread_id, nil), do: :ok

  defp check_expected_rev(repo, thread_id, expected_rev) do
    current_rev = fetch_thread_rev(repo, thread_id)

    if current_rev == expected_rev do
      :ok
    else
      {:error, :conflict}
    end
  end

  defp fetch_thread_rev(repo, thread_id) do
    case repo.one(
           from(m in "jido_thread_meta",
             where: m.thread_id == ^thread_id,
             select: m.rev
           )
         ) do
      nil -> 0
      rev -> rev
    end
  end

  defp fetch_thread_meta(repo, thread_id) do
    case repo.one(
           from(m in "jido_thread_meta",
             where: m.thread_id == ^thread_id,
             select: {m.rev, m.metadata_bytea, m.created_at, m.updated_at}
           )
         ) do
      nil ->
        %{created_at: nil, updated_at: nil, metadata: %{}}

      {_rev, nil, created_at, updated_at} ->
        %{created_at: created_at, updated_at: updated_at, metadata: %{}}

      {_rev, metadata_bytea, created_at, updated_at} ->
        %{
          created_at: created_at,
          updated_at: updated_at,
          metadata: :erlang.binary_to_term(metadata_bytea)
        }
    end
  end

  defp insert_entries(repo, thread_id, entries, _now) do
    rows =
      Enum.map(entries, fn entry ->
        %{
          thread_id: thread_id,
          seq: entry.seq,
          entry_bytea: :erlang.term_to_binary(entry)
        }
      end)

    if rows != [] do
      repo.insert_all("jido_thread_entries", rows)
    end

    :ok
  end

  defp upsert_thread_meta(repo, thread_id, entries, now, opts) do
    entry_count = length(entries)
    new_rev = fetch_thread_rev(repo, thread_id) + entry_count
    metadata = Keyword.get(opts, :metadata, %{})
    metadata_bytea = :erlang.term_to_binary(metadata)

    case repo.one(
           from(m in "jido_thread_meta",
             where: m.thread_id == ^thread_id,
             select: m.created_at
           )
         ) do
      nil ->
        repo.query!(
          """
          INSERT INTO jido_thread_meta (thread_id, rev, metadata_bytea, created_at, updated_at)
          VALUES ($1, $2, $3, $4, $4)
          """,
          [thread_id, new_rev, metadata_bytea, now]
        )

      _existing ->
        repo.query!(
          """
          UPDATE jido_thread_meta
          SET rev = $2, metadata_bytea = COALESCE($3, metadata_bytea), updated_at = $4
          WHERE thread_id = $1
          """,
          [thread_id, new_rev, metadata_bytea, now]
        )
    end

    :ok
  end

  defp reconstruct_thread(thread_id, entries, meta) do
    entry_count = length(entries)

    %Thread{
      id: thread_id,
      rev: entry_count,
      entries: entries,
      created_at: meta[:created_at] || (List.first(entries) && List.first(entries).at),
      updated_at: meta[:updated_at] || (List.last(entries) && List.last(entries).at),
      metadata: meta[:metadata] || %{},
      stats: %{entry_count: entry_count}
    }
  end
end
