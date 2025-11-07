defmodule LLMDb.Index do
  @moduledoc """
  Builds runtime indexes for fast model lookups.

  This module is used at LOAD TIME to build indexes from the snapshot data.
  The snapshot contains the nested v2 structure (providers with nested models),
  and this module creates the flat lookup indexes needed for O(1) access.
  """

  @doc """
  Builds lookup indexes for providers, models, and aliases.

  ## Parameters

  - `providers` - List of provider maps
  - `models` - List of model maps

  ## Returns

  A map with:
  - `:providers_by_id` - %{atom => Provider.t()}
  - `:models_by_key` - %{{atom, String.t()} => Model.t()}
  - `:models_by_provider` - %{atom => [Model.t()]}
  - `:aliases_by_key` - %{{atom, String.t()} => String.t()}
  """
  @spec build(providers :: [map()], models :: [map()]) :: map()
  def build(providers, models) do
    providers_by_id = Map.new(providers, fn p -> {p.id, p} end)

    models_by_key = Map.new(models, fn m -> {{m.provider, m.id}, m} end)

    models_by_provider =
      Enum.group_by(models, & &1.provider)
      |> Map.new(fn {provider, models_list} -> {provider, models_list} end)

    aliases_by_key = build_aliases_index(models)

    %{
      providers_by_id: providers_by_id,
      models_by_key: models_by_key,
      models_by_provider: models_by_provider,
      aliases_by_key: aliases_by_key
    }
  end

  @doc """
  Builds an alias index mapping {provider, alias} to canonical model ID.

  ## Parameters

  - `models` - List of model maps

  ## Returns

  %{{provider_atom, alias_string} => canonical_id_string}
  """
  @spec build_aliases_index([map()]) :: %{{atom(), String.t()} => String.t()}
  def build_aliases_index(models) do
    models
    |> Enum.flat_map(fn model ->
      provider = model.provider
      canonical_id = model.id
      aliases = Map.get(model, :aliases, [])

      Enum.map(aliases, fn alias_name ->
        {{provider, alias_name}, canonical_id}
      end)
    end)
    |> Map.new()
  end
end
