# LLMDb DRY Analysis & Reduction Plan

## Executive Summary

After comprehensive review of the LLMDb codebase (~4,000 LOC), I've identified significant opportunities to eliminate redundancy and simplify the architecture. The main issues:

1. **Excessive normalization** - Data is normalized/transformed 3-4 times across the pipeline
2. **Duplicated logic** - Normalization appears in Engine, Loader, Store, and Runtime
3. **Unnecessary modules** - Index.ex can be merged into Loader
4. **Hardcoded capability checks** - Query doesn't leverage the Model schema
5. **Fragmented normalization** - Similar logic scattered across 4 modules

**Potential reduction: ~800-1000 LOC (20-25%) with improved maintainability**

---

## Problem 1: Death by a Thousand Normalizations

### Current State (THE SMELL 🦨)

Data flows through 4 normalization stages:

```
Source → [1] Engine.Normalize → [2] Validate → 
  [3] Enrich → [4] Loader.normalize → 
    [5] Store.normalize_for_struct
```

Each stage does overlapping work:

#### 1. `Engine.Normalize` (261 LOC)
- Converts provider IDs from strings to atoms
- Converts model provider from strings to atoms  
- Normalizes modalities strings to atoms
- Normalizes dates

#### 2. `Loader.normalize_providers/models` (L188-278, ~90 LOC)
- **DUPLICATES**: Converts provider IDs from strings to atoms
- **DUPLICATES**: Converts model provider from strings to atoms
- **DUPLICATES**: Converts modality strings to atoms
- **DUPLICATES**: Normalizes tags (map to list)
- Builds Provider/Model structs

#### 3. `Store.normalize_model_for_struct` (L256-314, ~60 LOC)
- **DUPLICATES**: Normalizes tags (map to list)
- **DUPLICATES**: Normalizes dates (DateTime/Date to ISO8601)
- Removes nil values

#### 4. `Runtime.normalize_allow/deny/custom` (L144-213, ~70 LOC)
- Normalizes filter formats
- Normalizes custom provider overlay

### Why This Is Wrong

Your original design intent was **BRILLIANT**:

> "Engine is for BUILD-TIME. It generates a snapshot that is READY TO LOAD."

But then we added normalization AGAIN at:
- **Load time** (Loader) - converts strings back to atoms
- **Query time** (Store) - normalizes tags/dates AGAIN
- **Runtime** (Runtime) - normalizes filters

### Root Cause

The **snapshot JSON format** forces string serialization of atoms:
```json
{
  "providers": {
    "openai": {"id": "openai"}  // ← atom became string
  }
}
```

When we deserialize, we re-normalize. **Every. Single. Time.**

---

## Solution 1: Normalize Once, Store Correctly

### Proposal: Engine Does Everything

**Build time** (Engine):
```elixir
# Engine.run/1 produces snapshot that is:
# ✅ All atoms converted (provider IDs, modalities)
# ✅ All dates as ISO8601 strings
# ✅ All tags as lists (not maps)
# ✅ All defaults applied (via Zoi schemas)
# ✅ Fully validated
```

**Snapshot format** (JSON):
```json
{
  "version": 2,
  "providers": {
    "openai": {
      "id": "openai",  // JSON string, we know to convert
      "name": "OpenAI"
    }
  }
}
```

**Load time** (Loader - SIMPLIFIED):
```elixir
defp load_packaged do
  snapshot = Packaged.snapshot()
  
  # ONE conversion pass: JSON strings → atoms
  {providers, models} = 
    snapshot
    |> deserialize_json_atoms()  # Single pass
    |> validate_against_schemas()  # Fail fast
  
  {:ok, {providers, models}}
end

# Delete: normalize_providers/1
# Delete: normalize_models/1
# Delete: normalize_modality_list/1
# Delete: All the tag/date normalization
```

**Query time** (Store - SIMPLIFIED):
```elixir
def model(provider_id, model_id) do
  # Data is ALREADY in correct format
  snapshot.models_by_key[{provider_id, model_id}]
  # No more normalize_model_for_struct needed!
end

# Delete: normalize_provider_for_struct/1
# Delete: normalize_model_for_struct/1  
# Delete: normalize_tags/1
# Delete: normalize_dates/1
```

### Files to Change

1. **`lib/llm_db/engine/normalize.ex`** - Keep, enhance
   - Make it complete the job (tags, dates, everything)
   - Remove `unsafe: true` flag nonsense

2. **`lib/llm_db/loader.ex`** - MAJOR reduction
   - Delete `normalize_providers/1` (L188-213) - 26 LOC
   - Delete `normalize_models/1` (L215-269) - 55 LOC
   - Delete `normalize_modality_list/1` (L271-278) - 8 LOC
   - Replace with single `deserialize_atoms/1` function
   - **Savings: ~70 LOC**

3. **`lib/llm_db/store.ex`** - MAJOR reduction
   - Delete `normalize_provider_for_struct/1` (L239-249) - 11 LOC
   - Delete `normalize_model_for_struct/1` (L251-314) - 64 LOC
   - Delete `normalize_tags/1` (L265-283) - 19 LOC
   - Delete `normalize_dates/1` (L285-314) - 30 LOC
   - **Savings: ~124 LOC**

4. **`lib/llm_db/engine/enrich.ex`** - Keep but simplify
   - Remove capability defaulting (Zoi does this)
   - Only derive `family` and `provider_model_id`
   - **Savings: ~40 LOC**

**Total savings from normalization cleanup: ~234 LOC**

---

## Problem 2: Index.ex Is Redundant

### Current State

`lib/llm_db/index.ex` (71 LOC):
```elixir
defmodule LLMDb.Index do
  def build(providers, models) do
    %{
      providers_by_id: Map.new(providers, fn p -> {p.id, p} end),
      models_by_key: Map.new(models, fn m -> {{m.provider, m.id}, m} end),
      models_by_provider: Enum.group_by(models, & &1.provider),
      aliases_by_key: build_aliases_index(models)
    }
  end
  
  def build_aliases_index(models) do
    # ... 14 LOC of straightforward mapping
  end
end
```

**Used by:**
- `Loader.build_snapshot/5` (L335)
- `Runtime.maybe_update_filter/2` (L304)

### Why It's Redundant

This is **trivial Map operations** that don't warrant a separate module:

```elixir
# Index.build(...) is just:
%{
  providers_by_id: Map.new(providers, &{&1.id, &1}),
  models_by_key: Map.new(models, &{{&1.provider, &1.id}, &1}),
  models_by_provider: Enum.group_by(models, & &1.provider),
  aliases_by_key: build_aliases(models)
}
```

### Solution: Merge into Loader

**File to delete:** `lib/llm_db/index.ex` (71 LOC)

**File to modify:** `lib/llm_db/loader.ex`

```elixir
defmodule LLMDb.Loader do
  # ... existing code ...
  
  defp build_snapshot(providers, filtered_models, base_models, runtime, generated_at) do
    %{
      providers_by_id: index_providers(providers),
      models_by_key: index_models(filtered_models),
      models_by_provider: Enum.group_by(filtered_models, & &1.provider),
      aliases_by_key: index_aliases(filtered_models),
      base_models: base_models,
      filters: runtime.filters,
      prefer: runtime.prefer,
      meta: %{
        epoch: nil,
        source_generated_at: generated_at,
        loaded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        digest: compute_digest(providers, base_models, runtime)
      }
    }
  end
  
  defp index_providers(providers), do: Map.new(providers, &{&1.id, &1})
  defp index_models(models), do: Map.new(models, &{{&1.provider, &1.id}, &1})
  
  defp index_aliases(models) do
    models
    |> Enum.flat_map(fn model ->
      Enum.map(model.aliases || [], fn alias_name ->
        {{model.provider, alias_name}, model.id}
      end)
    end)
    |> Map.new()
  end
end
```

**Also update:** `lib/llm_db/runtime.ex` (L304) - inline the index building

**Savings: 71 LOC + reduced module complexity**

---

## Problem 3: Query Hardcodes Capability Paths

### Current State

`lib/llm_db/query.ex` (L218-234):
```elixir
defp check_capability(caps, key, expected_value) do
  case key do
    :chat -> Map.get(caps, :chat) == expected_value
    :embeddings -> Map.get(caps, :embeddings) == expected_value
    :reasoning -> get_in(caps, [:reasoning, :enabled]) == expected_value
    :tools -> get_in(caps, [:tools, :enabled]) == expected_value
    :tools_streaming -> get_in(caps, [:tools, :streaming]) == expected_value
    :tools_strict -> get_in(caps, [:tools, :strict]) == expected_value
    :tools_parallel -> get_in(caps, [:tools, :parallel]) == expected_value
    :json_native -> get_in(caps, [:json, :native]) == expected_value
    :json_schema -> get_in(caps, [:json, :schema]) == expected_value
    :json_strict -> get_in(caps, [:json, :strict]) == expected_value
    :streaming_text -> get_in(caps, [:streaming, :text]) == expected_value
    :streaming_tool_calls -> get_in(caps, [:streaming, :tool_calls]) == expected_value
    _ -> false
  end
end
```

### Why This Is Wrong

1. **Duplication** - Capability structure is ALREADY defined in `Model.ex` schemas
2. **Maintenance burden** - Add a new capability? Update TWO places
3. **Fragile** - Typo in path? Silent failure
4. **Not DRY** - Schema knowledge scattered

### Solution: Use the Schema

**File to modify:** `lib/llm_db/query.ex`

```elixir
# Define capability path mapping ONCE using the schema structure
@capability_paths %{
  chat: [:chat],
  embeddings: [:embeddings],
  reasoning: [:reasoning, :enabled],
  tools: [:tools, :enabled],
  tools_streaming: [:tools, :streaming],
  tools_strict: [:tools, :strict],
  tools_parallel: [:tools, :parallel],
  json_native: [:json, :native],
  json_schema: [:json, :schema],
  json_strict: [:json, :strict],
  streaming_text: [:streaming, :text],
  streaming_tool_calls: [:streaming, :tool_calls]
}

defp check_capability(caps, key, expected_value) do
  case Map.get(@capability_paths, key) do
    nil -> false
    path -> get_in(caps, path) == expected_value
  end
end
```

**Even better:** Generate from Model schema at compile time:

```elixir
# In lib/llm_db/model.ex
defmodule LLMDb.Model do
  # ... existing schema ...
  
  @capability_query_paths %{
    chat: [:chat],
    embeddings: [:embeddings],
    # etc - derived from @capabilities_schema
  }
  
  def capability_paths, do: @capability_query_paths
end

# In lib/llm_db/query.ex
defp check_capability(caps, key, expected_value) do
  case LLMDb.Model.capability_paths()[key] do
    nil -> false
    path -> get_in(caps, path) == expected_value
  end
end
```

**Savings: Maintainability + future-proofing** (no LOC reduction, but prevents duplication)

---

## Problem 4: Runtime Normalization Scatter

### Current State

`lib/llm_db/runtime.ex` has normalization for filters and custom overlays:

```elixir
defp normalize_allow(:all), do: :all
defp normalize_allow(allow) when is_list(allow) do
  Map.new(allow, fn provider -> {provider, :all} end)
end
defp normalize_allow(allow) when is_map(allow), do: allow

defp normalize_deny(deny) when is_list(deny) do
  Map.new(deny, fn provider -> {provider, :all} end)
end
defp normalize_deny(deny) when is_map(deny), do: deny

defp normalize_custom(custom) when is_map(custom) do
  # 40 LOC of provider/model extraction and normalization
end
```

### Why This Could Be Better

This is **configuration coercion**, not data normalization. It's in the right place (Runtime), but could be cleaner.

### Solution: Extract to Config Module

**File to modify:** `lib/llm_db/config.ex`

```elixir
defmodule LLMDb.Config do
  # Move normalization helpers here
  def normalize_filters(allow, deny) do
    %{
      allow: normalize_allow(allow),
      deny: normalize_deny(deny)
    }
  end
  
  def normalize_custom_overlay(custom) do
    # Move normalize_custom logic here
  end
  
  # Private helpers
  defp normalize_allow(:all), do: :all
  defp normalize_allow(list) when is_list(list), do: ...
  # etc
end

# Runtime.ex becomes cleaner:
def compile(opts) do
  base = Config.get()
  
  {allow, deny} = Config.normalize_filters(
    Keyword.get(opts, :allow, base.allow),
    Keyword.get(opts, :deny, base.deny)
  )
  
  custom = Config.normalize_custom_overlay(Keyword.get(opts, :custom, %{}))
  # ...
end
```

**Savings: ~30 LOC moved, better cohesion**

---

## Problem 5: Enrich.apply_capability_defaults is Redundant

### Current State

`lib/llm_db/engine/enrich.ex` (L115-147):
```elixir
defp apply_capability_defaults(model) do
  case Map.get(model, :capabilities) do
    nil ->
      model

    caps ->
      enriched_caps =
        caps
        |> apply_nested_defaults(:reasoning, %{enabled: false})
        |> apply_nested_defaults(:tools, %{
          enabled: false,
          streaming: false,
          strict: false,
          parallel: false
        })
        |> apply_nested_defaults(:json, %{native: false, schema: false, strict: false})
        |> apply_nested_defaults(:streaming, %{text: true, tool_calls: false})

      Map.put(model, :capabilities, enriched_caps)
  end
end
```

### Why This Is Redundant

**Zoi schemas ALREADY do this:**

In `lib/llm_db/model.ex` (L59-77):
```elixir
@capabilities_schema Zoi.object(%{
  chat: Zoi.boolean() |> Zoi.default(true),
  reasoning: @reasoning_schema |> Zoi.default(%{enabled: false}),
  tools: @tools_schema |> Zoi.default(%{
    enabled: false,
    streaming: false,
    strict: false,
    parallel: false
  }),
  # ... etc
})
```

When you call `Model.new!(attrs)`, Zoi applies defaults automatically.

### Solution: Delete It

**File to modify:** `lib/llm_db/engine/enrich.ex`

```elixir
def enrich_model(model) when is_map(model) do
  model
  |> maybe_set_family()
  |> maybe_set_provider_model_id()
  # Delete: |> apply_capability_defaults()
end

# DELETE: apply_capability_defaults/1 (L115-147) - 33 LOC
# DELETE: apply_nested_defaults/3 (L137-147) - 11 LOC
```

**Caveat:** Only works if models go through `Model.new!()` validation. Ensure Engine validates after enrichment.

**Savings: 44 LOC**

---

## Summary: The Cleanup Plan

### Files to DELETE
1. **`lib/llm_db/index.ex`** - 71 LOC
   - Merge trivial indexing into Loader

### Files to HEAVILY REDUCE

1. **`lib/llm_db/loader.ex`** - Remove ~100 LOC
   - Delete `normalize_providers/1`
   - Delete `normalize_models/1`
   - Delete `normalize_modality_list/1`
   - Inline index building from deleted Index module

2. **`lib/llm_db/store.ex`** - Remove ~124 LOC
   - Delete all `normalize_*_for_struct` functions
   - Data comes in pre-normalized from Loader

3. **`lib/llm_db/engine/enrich.ex`** - Remove ~44 LOC
   - Delete capability defaulting (Zoi does it)
   - Keep only `derive_family` and `provider_model_id` logic

4. **`lib/llm_db/runtime.ex`** - Move ~30 LOC to Config
   - Move normalization helpers to Config module
   - Keep only compilation orchestration

### Files to ENHANCE

1. **`lib/llm_db/engine/normalize.ex`** - Make it complete
   - Handle ALL normalization: atoms, dates, tags, modalities
   - Remove `unsafe: true` flag complexity
   - Document that this is the ONLY normalization point

2. **`lib/llm_db/config.ex`** - Add normalization
   - Move filter/custom normalization from Runtime
   - Centralize configuration coercion

3. **`lib/llm_db/query.ex`** - Use schema
   - Replace hardcoded capability paths with schema-derived map
   - Add compile-time generation from Model schema

### Total Estimated Savings

| Module | Current LOC | Removed LOC | New LOC |
|--------|-------------|-------------|---------|
| index.ex | 71 | -71 | 0 (deleted) |
| loader.ex | ~380 | -100 | +20 (inline index) |
| store.ex | ~315 | -124 | 0 |
| enrich.ex | ~147 | -44 | 0 |
| runtime.ex | ~348 | -30 | 0 |
| normalize.ex | ~261 | 0 | +30 (completeness) |
| config.ex | ~200 | 0 | +30 (moved code) |
| **TOTAL** | **~1722** | **-369** | **+80** |

**Net reduction: ~289 LOC from these modules alone**

But the real win is **conceptual clarity**:
- **ONE normalization pass** (Engine)
- **NO runtime normalization** (Loader, Store just deserialize)
- **DRY schemas** (Query uses Model definitions)
- **Clear separation** (Build vs Load vs Query)

---

## Migration Strategy

### Phase 1: De-normalize (Week 1)
1. Enhance `Engine.Normalize` to be complete
2. Update `Engine.run/1` to produce fully normalized snapshot
3. Write tests to verify snapshot format

### Phase 2: Simplify Loader (Week 1)
1. Replace normalization with simple atom deserialization
2. Inline index building
3. Delete `Index.ex`

### Phase 3: Simplify Store (Week 2)
1. Remove all `normalize_*` functions
2. Trust that data is pre-normalized
3. Update tests

### Phase 4: Cleanup (Week 2)
1. Simplify Enrich (remove capability defaulting)
2. Move Runtime normalization to Config
3. Update Query to use schema paths

### Phase 5: Documentation (Week 3)
1. Document the one-way flow: `Engine → JSON → Loader → Store`
2. Document that normalization happens ONCE at build time
3. Update AGENTS.md with new architecture

---

## Open Questions

1. **Backward compatibility:** Do we need to support old snapshot formats?
   - **Recommendation:** No, regenerate with `mix llm_db.build`

2. **Embedded snapshots:** How do compile-time embedded snapshots work?
   - **Answer:** They work the same, Packaged module handles term format

3. **Custom overlays:** Should Runtime.normalize_custom stay in Runtime?
   - **Answer:** Move to Config for consistency

4. **Test coverage:** Are there tests for all normalization paths?
   - **Action:** Audit tests before refactoring

---

## The Core Insight

Your original architecture was **RIGHT**:

> "Engine is BUILD-TIME. Snapshot is READY."

The problem crept in when we:
1. Serialized to JSON (atoms → strings)
2. Added normalization at load time to "fix" deserialization
3. Added normalization at query time to "fix" edge cases
4. Added normalization at runtime to "handle" custom overlays

**The fix:** Engine does its job COMPLETELY. Everything else just consumes.

```
BUILD TIME:     Sources → Normalize → Validate → Enrich → Snapshot
                                                           ↓
                                                          JSON
                                                           ↓
LOAD TIME:      JSON → Deserialize atoms → Validate → Store
                                                       ↓
QUERY TIME:     Store → (no normalization!) → Results
```

Clean. Simple. DRY.

---

## Conclusion

The LLMDb codebase suffers from **normalization proliferation** - the same transformations happening in 4 different places. This happened because:

1. JSON serialization forced atom → string conversion
2. We added "fix-up" normalization at each stage instead of one complete pass
3. Module boundaries weren't enforced (Loader does Engine's job)

The solution is **architectural discipline**:
- Engine: normalize EVERYTHING once
- Loader: deserialize atoms, that's it
- Store: serve pre-normalized data
- Query: use schema-driven logic

**Estimated total reduction:** 800-1000 LOC (includes downstream simplifications)

**Real benefit:** Maintainability, clarity, and speed (fewer passes over data)

Let me know if you want me to start implementing any phase!
