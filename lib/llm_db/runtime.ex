defmodule LLMDb.Runtime do
  @moduledoc """
  Runtime filtering and preference updates without running the full Engine.

  Apply runtime overrides to an existing snapshot:
  - Recompile and reapply filters (allow/deny patterns)
  - Update provider preferences

  Unlike the full Engine pipeline, this does not add new providers/models,
  run normalization/validation, or modify provider/model data.

  ## Example

      snapshot = LLMDb.Store.snapshot()
      overrides = %{
        filter: %{
          allow: %{openai: ["gpt-4"]},
          deny: %{}
        },
        prefer: [:openai, :anthropic]
      }

      {:ok, updated_snapshot} = LLMDb.Runtime.apply(snapshot, overrides)
  """

  alias LLMDb.{Config, Engine}

  @doc """
  Applies runtime overrides to an existing snapshot.

  ## Parameters

  - `snapshot` - The current snapshot map
  - `overrides` - Map with optional `:filter` and `:prefer` keys

  ## Override Options

  - `:filter` - %{allow: patterns, deny: patterns} to recompile and reapply
  - `:prefer` - List of provider atoms to update preference order

  ## Returns

  - `{:ok, updated_snapshot}` - Success with updated snapshot
  - `{:error, reason}` - Validation or processing error
  """
  @spec apply(map(), map() | nil) :: {:ok, map()} | {:error, term()}
  def apply(snapshot, overrides) when is_map(snapshot) do
    case validate_and_prepare_overrides(overrides) do
      {:ok, prepared} ->
        apply_overrides(snapshot, prepared)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_and_prepare_overrides(nil), do: {:ok, %{}}
  defp validate_and_prepare_overrides(overrides) when overrides == %{}, do: {:ok, %{}}

  defp validate_and_prepare_overrides(overrides) when is_map(overrides) do
    with :ok <- validate_filter(overrides[:filter]),
         :ok <- validate_prefer(overrides[:prefer]) do
      {:ok, overrides}
    end
  end

  defp validate_filter(nil), do: :ok
  defp validate_filter(%{} = filter) when map_size(filter) == 0, do: :ok

  defp validate_filter(%{allow: allow, deny: deny}) do
    allow_ok = allow in [:all, nil] or is_map(allow)
    deny_ok = deny == nil or is_map(deny)

    if allow_ok and deny_ok do
      :ok
    else
      {:error, "filter.allow must be :all or map; filter.deny must be map"}
    end
  end

  defp validate_filter(_), do: {:error, "filter must be %{allow: ..., deny: ...}"}

  defp validate_prefer(nil), do: :ok
  defp validate_prefer([]), do: :ok

  defp validate_prefer(prefer) when is_list(prefer) do
    if Enum.all?(prefer, &is_atom/1) do
      :ok
    else
      {:error, "prefer must be a list of atoms"}
    end
  end

  defp validate_prefer(_), do: {:error, "prefer must be a list of atoms"}

  defp apply_overrides(snapshot, overrides) do
    snapshot
    |> maybe_update_filter(overrides[:filter])
    |> maybe_update_prefer(overrides[:prefer])
    |> wrap_ok()
  end

  defp maybe_update_filter(snapshot, nil), do: {:ok, snapshot}
  defp maybe_update_filter(snapshot, filter) when map_size(filter) == 0, do: {:ok, snapshot}

  defp maybe_update_filter(snapshot, filter) do
    alias LLMDb.{Config, Engine, Index}

    require Logger

    # Get known provider IDs for validation
    provider_ids = Map.keys(snapshot.providers_by_id)

    # Compile filters with provider validation
    {compiled_filters, unknown: unknown_providers} =
      Config.compile_filters(
        Map.get(filter, :allow, :all),
        Map.get(filter, :deny, %{}),
        provider_ids
      )

    # Warn on unknown providers in runtime overrides
    if unknown_providers != [] do
      provider_ids_set = MapSet.new(provider_ids)

      Logger.warning(
        "llm_db: unknown provider(s) in runtime filter: #{inspect(unknown_providers)}. " <>
          "Known providers: #{inspect(MapSet.to_list(provider_ids_set))}. " <>
          "Check spelling or remove unknown providers from runtime overrides."
      )
    end

    # Use base_models to enable filter widening, fall back to current models
    all_models = Map.get(snapshot, :base_models, Map.values(snapshot.models) |> List.flatten())
    filtered_models = Engine.apply_filters(all_models, compiled_filters)

    # Fail fast if filters eliminate all models - return error instead of raise
    if compiled_filters.allow != :all and filtered_models == [] do
      allow_summary = summarize_runtime_filter(Map.get(filter, :allow, :all))
      deny_summary = summarize_runtime_filter(Map.get(filter, :deny, %{}))

      {:error,
       "llm_db: runtime filters eliminated all models " <>
         "(allow: #{allow_summary}, deny: #{deny_summary}). " <>
         "Use allow: :all to widen filters or remove deny patterns."}
    else
      indexes = Index.build(Map.values(snapshot.providers_by_id), filtered_models)

      updated_snapshot = %{
        snapshot
        | filters: compiled_filters,
          models_by_key: indexes.models_by_key,
          models: indexes.models_by_provider,
          aliases_by_key: indexes.aliases_by_key
      }

      {:ok, updated_snapshot}
    end
  end

  defp maybe_update_prefer({:ok, snapshot}, nil), do: {:ok, snapshot}
  defp maybe_update_prefer({:ok, snapshot}, []), do: {:ok, snapshot}

  defp maybe_update_prefer({:ok, snapshot}, prefer) when is_list(prefer) do
    {:ok, %{snapshot | prefer: prefer}}
  end

  defp maybe_update_prefer({:error, _} = error, _prefer), do: error

  defp wrap_ok({:ok, _} = result), do: result
  defp wrap_ok({:error, _} = error), do: error

  defp summarize_runtime_filter(:all), do: ":all"

  defp summarize_runtime_filter(filter) when is_map(filter) and map_size(filter) == 0 do
    "%{}"
  end

  defp summarize_runtime_filter(filter) when is_map(filter) do
    # Summarize large filter maps to avoid huge error messages
    keys = Map.keys(filter) |> Enum.take(5)

    if map_size(filter) > 5 do
      "#{inspect(keys)} ... (#{map_size(filter)} providers total)"
    else
      inspect(filter)
    end
  end

  defp summarize_runtime_filter(other), do: inspect(other)
end
