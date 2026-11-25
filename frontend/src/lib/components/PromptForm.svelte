<script lang="ts">
  import { untrack } from 'svelte';
  import ImageModelPicker from '$lib/components/ImageModelPicker.svelte';
  import { plainTextInput } from '$lib/actions/plainTextInput';
  import { promptForm } from '$lib/features/workspace/formState.svelte';
  import { t } from '$lib/i18n';
  import type { Snippet } from 'svelte';
  import type { PromptFormState } from '$lib/utils/promptFormTypes';
  import { MAX_CONCURRENT_SUBMISSIONS } from '$lib/stores/previewGroup';
  import { settingsStore } from '$lib/stores/settings';
  import { RESPONSE_FORMAT_OPTIONS, sanitizeQuantityInput } from '$lib/utils/promptForm';
  import { imageQualities, isImage25, isImage26, MAX_PROMPT_CHARS, promptLength } from '$lib/utils/imageModels';
  import {
    isPromptOnlyApiPath,
    isStreamUnavailableMapped,
    isStreamUnsupportedPath,
    isTransparentUnavailableMapped,
    normalizeForm
  } from '$lib/utils/promptRules';

  interface Props {
    loading?: boolean;
    optimizing?: boolean;
    optimizerEnabled?: boolean;
    editPlannerEnabled?: boolean;
    editPlanning?: boolean;
    hasEditSource?: boolean;
    hasEditMask?: boolean;
    activeSubmissions?: number;
    editSource?: Snippet;
    preview?: Snippet;
    onSubmit?: () => Promise<boolean> | boolean | void;
    onOpenSize?: () => void;
    onOptimize?: () => void;
    onPlanEdit?: () => void;
  }

  let {
    loading = false,
    optimizing = false,
    optimizerEnabled = false,
    editPlannerEnabled = false,
    editPlanning = false,
    hasEditSource = false,
    hasEditMask = false,
    activeSubmissions = 0,
    editSource,
    preview,
    onSubmit = () => {},
    onOpenSize = () => {},
    onOptimize = () => {},
    onPlanEdit = () => {}
  }: Props = $props();

  const promptLen = $derived(promptLength(promptForm.prompt));
  const qualities = $derived(imageQualities(promptForm.model));
  const image26 = $derived(isImage26(promptForm.model));
  const specialMedia = $derived(promptForm.outputFormat === 'svg' || promptForm.outputFormat === 'gif');
  let mediaReset = $state(false);
  let qualityResetModel = $state('');
  let moreSettingsOpen = $state(false);
  const image25 = $derived(isImage25(promptForm.model) || isImage26(promptForm.model));
  const promptOnlyMode = $derived(isPromptOnlyApiPath(promptForm.apiPath));
  const parameterControlsDisabled = $derived((promptOnlyMode && !hasEditSource) || loading);
  // Generation stays submittable while earlier requests are in flight and can
  // keep queuing (no cooldown, no cap). Only edit-mode mid-request greys.
  // Generate button stays enabled after each submit so the user can keep
  // queuing. Only an in-flight edit request blocks re-entry.
  const submitDisabled = $derived(loading && hasEditSource);

  async function handleSubmit() {
    // Generate stays freely clickable (no cooldown, no cap). Only an in-flight
    // edit request blocks re-entry.
    if (loading && hasEditSource) return;
    await onSubmit();
  }
  const modeLabel = $derived(promptForm.apiPath === '/v1/chat/completions' ? $t.promptForm.chatCompletionsMode : $t.promptForm.responsesMode);
  const disabledModeLabel = $derived(
    promptForm.apiPath === '/v1/chat/completions' ? $t.promptForm.disabledForChatCompletions : $t.promptForm.disabledForResponses
  );
  const optimizeDisabled = $derived(loading || optimizing || !optimizerEnabled || !promptForm.prompt.trim());
  // 尺寸比例示意: 解析 "WxH" -> 约分比例 + 像素框尺寸(宽>=高按宽34px, 竖版按高24px, auto 无框)
  const sizeRatio = $derived.by(() => {
    const m = /^(\d+)x(\d+)$/i.exec(promptForm.size.trim());
    if (!m) return null;
    const w = Number(m[1]), h = Number(m[2]);
    const gcd = (a: number, b: number): number => (b ? gcd(b, a % b) : a);
    const g = gcd(w, h);
    return { label: `${w / g}:${h / g}`, w, h };
  });
  const sizeGlyph = $derived.by(() => {
    if (!sizeRatio) return null;
    const r = sizeRatio.w / sizeRatio.h;
    return r >= 1
      ? { w: 34, h: Math.max(6, Math.round(34 / r)) }
      : { w: Math.max(6, Math.round(24 * r)), h: 24 };
  });
  // Mapped (async_json) presets publish their capability set from the backend;
  // the form mirrors it so unsupported options are disabled before submit.
  const providerCaps = $derived($settingsStore.settings?.provider_capabilities ?? null);
  const providerMapped = $derived(($settingsStore.settings?.provider_kind ?? 'openai') === 'async_json');

  const streamUnavailableReason = $derived(
    isStreamUnsupportedPath(promptForm.apiPath, hasEditSource)
      ? $t.promptForm.streamUnsupportedPath
      : isStreamUnavailableMapped(providerMapped, providerCaps)
        ? $t.promptForm.streamUnavailableMapped
        : ''
  );
  const streamDisabled = $derived(specialMedia || loading || Boolean(streamUnavailableReason));
  const transparentDisabledReason = $derived(
    isTransparentUnavailableMapped(providerMapped, providerCaps)
      ? $t.promptForm.transparentUnavailableMapped
      : ''
  );

  const NORMALIZED_FIELDS = [
    'model',
    'apiPath',
    'quality',
    'outputFormat',
    'complexity',
    'background',
    'outputCompression',
    'quantity',
    'stream'
  ] as const;

  // Track only capability-relevant fields and context so typing in the prompt
  // or editing size/frames never triggers capability normalization.
  $effect(() => {
    const capabilitySnapshot = {
      model: promptForm.model,
      apiPath: promptForm.apiPath,
      quality: promptForm.quality,
      outputFormat: promptForm.outputFormat,
      complexity: promptForm.complexity,
      background: promptForm.background,
      outputCompression: promptForm.outputCompression,
      quantity: promptForm.quantity,
      stream: promptForm.stream
    };
    const editMode = hasEditSource;
    const hasMask = hasEditMask;
    const mapped = providerMapped;
    const caps = providerCaps;

    const { form: normalized, resets } = untrack(() =>
      normalizeForm(
        { ...promptForm.snapshot(), ...capabilitySnapshot },
        { providerMapped: mapped, providerCaps: caps, editMode, hasMask }
      )
    );

    if (resets.length === 0) return;

    const updates: Partial<PromptFormState> = {};
    for (const key of NORMALIZED_FIELDS) {
      if (normalized[key] !== capabilitySnapshot[key]) {
        (updates as Record<string, unknown>)[key] = normalized[key];
      }
    }

    untrack(() => {
      if (Object.keys(updates).length > 0) {
        promptForm.patch(updates);
      }
      if (resets.includes('media_reset')) {
        mediaReset = true;
      }
      if (resets.includes('quality_reset')) {
        qualityResetModel = normalized.model;
      }
    });
  });

  function handleQuantityInput() {
    promptForm.quantity = sanitizeQuantityInput(promptForm.quantity);
  }

  function handlePromptKeydown(event: KeyboardEvent) {
    if (event.key !== 'Enter' || event.isComposing || event.repeat) return;
    if (!(event.ctrlKey || event.metaKey)) return;
    event.preventDefault();
    void handleSubmit();
  }

</script>

<section class="fp-workspace grid grid-cols-1 items-stretch gap-6 lg:grid-cols-3 lg:min-h-0">
  <!-- 左: 提示词 -->
  <section class="fp-col app-surface flex min-h-0 flex-col p-4 sm:p-5">
    <div class="mb-4 flex items-start justify-between gap-4">
      <div>
        <h2 class="text-sm font-semibold text-stone-950 dark:text-zinc-100">{$t.promptForm.title}</h2>
        <p class="mt-1 text-xs text-stone-500 dark:text-zinc-500">{$t.promptForm.subtitle}</p>
      </div>
      {#if promptOnlyMode}
        <span class="rounded-md border border-cyan-500/30 bg-cyan-500/10 px-2 py-1 text-xs font-medium text-cyan-200">{modeLabel}</span>
      {/if}
    </div>

    <div class="min-w-0 flex flex-1 flex-col">
      <div class="mb-2 flex items-center justify-between gap-3">
        <label for="prompt" class="text-xs font-medium text-stone-600 dark:text-zinc-400">{$t.common.prompt}</label>
        <button
          type="button"
          disabled={optimizeDisabled}
          class="control-focus rounded-lg border border-emerald-500/40 px-3 py-1.5 text-xs font-semibold text-emerald-700 hover:bg-emerald-500/10 disabled:cursor-not-allowed disabled:border-stone-300 disabled:bg-stone-100 disabled:text-stone-400 disabled:opacity-60 dark:border-emerald-500/30 dark:text-emerald-200 dark:disabled:border-zinc-700 dark:disabled:bg-zinc-800/50 dark:disabled:text-zinc-500"
          title={optimizerEnabled ? $t.promptForm.optimize : $t.promptForm.optimizerUnavailable}
          onclick={onOptimize}
        >
          {optimizing ? $t.promptForm.optimizing : $t.promptForm.optimize}
        </button>
      </div>
      <div class="relative flex min-h-[10rem] flex-1">
        <textarea
          id="prompt"
          name="prompt"
          bind:value={promptForm.prompt}
          aria-invalid={promptLen > MAX_PROMPT_CHARS}
          rows="6"
          autocomplete="off"
          spellcheck="false"
          aria-label={$t.common.prompt}
          placeholder={$t.promptForm.placeholder}
          class="ui-field h-full min-h-[10rem] flex-1 resize-y px-4 py-3 pb-8 leading-6 lg:resize-none"
          use:plainTextInput
          onkeydown={handlePromptKeydown}
        ></textarea>
        <div class="pointer-events-none absolute bottom-3 right-4 text-xs text-stone-500 dark:text-zinc-500">{promptLen}/{MAX_PROMPT_CHARS}</div>
      </div>
    </div>
  </section>

  <!-- 中: 预览(灰色外框, 同 提示词/参考图; 参数模块已移到右列参考图上方) -->
  <div class="fp-col app-surface flex min-h-0 flex-col gap-4 p-4 sm:p-5">
    <div class="fp-preview-wrap flex min-h-0 flex-1 flex-col overflow-hidden rounded-xl">
      {@render preview?.()}
    </div>
  </div>

  <!-- 右: 参数模块(模型/尺寸/更多设置, 紧凑) 在参考图上方 + 上传/编辑 + 生成 -->
  <section class="fp-col app-surface flex min-h-0 flex-col p-4 sm:p-5">
    <div class="min-h-0 flex-1 overflow-auto">
      <section class="app-surface mb-4 shrink-0 overflow-auto rounded-xl border border-stone-200/80 bg-stone-50/50 p-3.5 dark:border-zinc-800/80 dark:bg-zinc-950/40">
        <div class="app-well grid grid-cols-1 gap-x-3 gap-y-3 sm:grid-cols-2">
        <div class="sm:col-span-1">
          <ImageModelPicker bind:value={promptForm.model} disabled={loading} />
        </div>

        <div class="sm:col-span-1">
          <label class="block">
            <span class="mb-1.5 block text-xs font-medium text-stone-600 dark:text-zinc-400">{$t.common.size}</span>
            <div class="flex items-center gap-2.5">
              <button
                type="button"
                disabled={parameterControlsDisabled}
                class="control-focus flex h-10 min-w-0 flex-1 items-center justify-between rounded-lg border border-stone-200 bg-white px-3 text-left font-mono text-sm text-stone-900 hover:bg-stone-100 disabled:cursor-not-allowed disabled:opacity-50 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-100 dark:hover:bg-zinc-800"
                onclick={onOpenSize}
              >
                <span class="truncate">{promptOnlyMode && !hasEditSource ? disabledModeLabel : promptForm.size}</span>
                <span class="ml-1 text-xs text-stone-400 dark:text-zinc-500">⚙</span>
              </button>
              {#if sizeGlyph}
                <span class="flex shrink-0 flex-col items-center gap-1" title={`${promptForm.size} (${sizeRatio.label})`}>
                  <span class="flex h-9 w-11 items-center justify-center">
                    <span
                      class="rounded-sm border-2 border-emerald-500/70 bg-emerald-500/10 dark:border-emerald-400/60"
                      style={`width: ${sizeGlyph.w}px; height: ${sizeGlyph.h}px;`}
                    ></span>
                  </span>
                  <span class="font-mono text-[10px] leading-none text-stone-500 dark:text-zinc-400">{sizeRatio.label}</span>
                </span>
              {/if}
            </div>
          </label>
        </div>

        {#if image26}
          <div class="sm:col-span-2 grid grid-cols-1 gap-3 sm:grid-cols-2">
            <label class="block text-sm">{$t.promptForm.complexity}
              <select bind:value={promptForm.complexity} disabled={loading || (providerMapped && !providerCaps?.complexity)} class="form-select w-full">
                <option value={null}>{$t.promptForm.modelDefaultHigh}</option>
                <option value="low">{$t.promptForm.complexityLow}</option><option value="medium">{$t.promptForm.complexityMedium}</option><option value="high">{$t.promptForm.complexityHigh}</option>
              </select>
            </label>
            {#if promptForm.outputFormat === 'gif'}
              <label class="block text-sm">{$t.promptForm.frameCount}<input type="number" min="2" max="64" step="1" bind:value={promptForm.frameCount} class="ui-field w-full" /></label>
              <label class="block text-sm">{$t.promptForm.frameDuration}<input type="number" min="20" max="2000" step="10" bind:value={promptForm.frameDurationMs} class="ui-field w-full" /></label>
            {/if}
          </div>
        {/if}

        <div class="sm:col-span-2">
          <button
            type="button"
            class="control-focus flex w-full items-center justify-between rounded-lg border border-stone-200/80 bg-white px-3 py-2 text-xs font-medium text-stone-600 hover:bg-stone-50 dark:border-zinc-800/80 dark:bg-zinc-950/40 dark:text-zinc-300 dark:hover:bg-zinc-900/60"
            aria-expanded={moreSettingsOpen}
            onclick={() => (moreSettingsOpen = !moreSettingsOpen)}
          >
            <span>{moreSettingsOpen ? $t.promptForm.lessSettings : $t.promptForm.moreSettings}</span>
            <span class="text-stone-400 dark:text-zinc-500">{moreSettingsOpen ? '▴' : '▾'}</span>
          </button>
        </div>

        {#if moreSettingsOpen}
        <label class="block">
          <span class="mb-1.5 block text-xs font-medium text-stone-600 dark:text-zinc-400">{$t.promptForm.quality}</span>
          <select bind:value={promptForm.quality} aria-label={$t.promptForm.quality} disabled={parameterControlsDisabled} class="control-focus form-select w-full !bg-white focus:border-emerald-500 dark:!bg-zinc-900">
            {#each qualities as quality}<option value={quality}>{quality}</option>{/each}
          </select>
          {#if qualityResetModel === promptForm.model && promptForm.quality === 'auto'}<p role="status" class="mt-1 text-xs text-stone-500">{$t.promptForm.qualityReset}</p>{/if}
        </label>

        <label class="block">
          <span class="mb-1.5 block text-xs font-medium text-stone-600 dark:text-zinc-400">{$t.promptForm.quantity}</span>
          <input
            bind:value={promptForm.quantity}
            disabled={parameterControlsDisabled}
            type="text"
            inputmode="numeric"
            pattern="[0-9]*"
            class="control-focus h-10 w-full rounded-lg border border-stone-200 bg-white px-3 text-sm text-stone-900 focus:border-emerald-500 disabled:cursor-not-allowed disabled:opacity-50 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-100"
            oninput={handleQuantityInput}
          />
        </label>

        <label class="block">
          <span class="mb-1.5 block text-xs font-medium text-stone-600 dark:text-zinc-400">{$t.promptForm.format}</span>
          <select bind:value={promptForm.outputFormat} disabled={parameterControlsDisabled} class="control-focus form-select w-full !bg-white focus:border-emerald-500 dark:!bg-zinc-900">
            <option value="png">png</option>
            <option value="jpeg">jpeg</option>
            <option value="webp">webp</option>
            {#if image26}{#if !hasEditSource && (!providerMapped || providerCaps?.formats.includes('svg'))}<option value="svg">svg</option>{/if}{#if !hasEditMask && (!providerMapped || (providerCaps?.animation && providerCaps?.formats.includes('gif')))}<option value="gif">gif</option>{/if}{/if}
          </select>
        </label>

        <label class="block">
          <span class="mb-1.5 block text-xs font-medium text-stone-600 dark:text-zinc-400">{$t.promptForm.background}</span>
          <select bind:value={promptForm.background} disabled={parameterControlsDisabled} class="control-focus form-select w-full !bg-white focus:border-emerald-500 dark:!bg-zinc-900">
            <option value="auto">{$t.promptForm.backgroundAuto}</option>
            <option value="opaque">{$t.promptForm.backgroundOpaque}</option>
            <option value="transparent" disabled={Boolean(transparentDisabledReason)}>{$t.promptForm.backgroundTransparent}</option>
            {#if !hasEditSource && !promptOnlyMode}
              <option value="chroma_green">{$t.promptForm.backgroundChromaGreen}</option>
              <option value="chroma_magenta">{$t.promptForm.backgroundChromaMagenta}</option>
            {/if}
          </select>
          {#if promptForm.background?.startsWith('chroma_')}
            <p class="mt-1 text-xs text-stone-500 dark:text-zinc-400">{$t.promptForm.chromaHint}</p>
          {:else if transparentDisabledReason}
            <p class="mt-1 text-xs text-stone-500 dark:text-zinc-400">{transparentDisabledReason}</p>
          {/if}
          {#if promptForm.background === 'transparent' && promptForm.outputFormat === 'jpeg'}
            <p class="mt-1 text-xs text-amber-600 dark:text-amber-400">{$t.promptForm.backgroundTransparentNote}</p>
          {/if}
        </label>

        <label class="block">
          <span class="mb-1.5 block text-xs font-medium text-stone-600 dark:text-zinc-400">{$t.promptForm.apiPath}</span>
          <select bind:value={promptForm.apiPath} disabled={loading} class="control-focus form-select w-full !bg-white font-mono focus:border-emerald-500 dark:!bg-zinc-900">
            <option value="/v1/images/generations">/v1/images/generations</option>
            <option value="/v1/responses">/v1/responses</option>
            <option value="/v1/chat/completions">/v1/chat/completions</option>
          </select>
        </label>

        <label class="block">
          <span class="mb-1.5 block text-xs font-medium text-stone-600 dark:text-zinc-400">{$t.promptForm.responseFormat}</span>
          <select value={image25 ? '' : promptForm.responseFormat} onchange={(event) => (promptForm.responseFormat = event.currentTarget.value as PromptFormState['responseFormat'])} disabled={parameterControlsDisabled || image25} class="control-focus form-select w-full !bg-white focus:border-emerald-500 dark:!bg-zinc-900">
            {#each RESPONSE_FORMAT_OPTIONS as responseFormat}
              <option value={responseFormat}>{responseFormat || (image25 ? $t.promptForm.base64Automatic : $t.promptForm.defaultResponseFormat)}</option>
            {/each}
          </select>
        </label>

        <div class="sm:col-span-2">
          <label class="mobile-touch-target flex items-center gap-2 text-xs font-medium text-stone-600 dark:text-zinc-400">
            <input type="checkbox" class="h-3.5 w-3.5 accent-emerald-500" bind:checked={promptForm.stream} disabled={streamDisabled} />
            {$t.promptForm.streamToggle}
          </label>
          {#if promptForm.stream && !streamDisabled}
            <label class="mt-2 flex items-center gap-2 text-xs font-medium text-stone-600 dark:text-zinc-400">
              {$t.promptForm.streamPartialImages}
              <select
                bind:value={promptForm.partialImages}
                aria-label={$t.promptForm.streamPartialImages}
                class="control-focus form-select !bg-white text-xs focus:border-emerald-500 dark:!bg-zinc-900"
              >
                <option value={1}>1</option>
                <option value={2}>2</option>
                <option value={3}>3</option>
              </select>
            </label>
          {/if}
          {#if streamUnavailableReason}
            <p class="mt-1 text-xs text-stone-500 dark:text-zinc-500">{streamUnavailableReason}</p>
          {:else if promptForm.stream}
            <p class="mt-1 text-xs text-stone-500 dark:text-zinc-500">{$t.promptForm.streamCostNote}</p>
          {/if}
        </div>
        {#if mediaReset}<p role="status" class="text-sm text-amber-700 sm:col-span-2 dark:text-amber-300">{$t.promptForm.mediaReset}</p>{/if}
        {/if}
      </div>
    </section>

      {@render editSource?.()}
    </div>

    <div class="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-stone-200/80 pt-4 dark:border-zinc-800/80">
      <div class="flex items-center gap-2 text-xs text-stone-500 dark:text-zinc-400">
        {#if hasEditSource}
          <span class="inline-flex items-center gap-1.5 rounded-full bg-emerald-500/10 px-2.5 py-1 font-medium text-emerald-700 dark:text-emerald-300">
            <span class="h-1.5 w-1.5 rounded-full bg-emerald-500 animate-pulse"></span>
            {$t.promptForm.edits}
          </span>
        {:else}
          <span class="inline-flex items-center gap-1.5 rounded-full bg-stone-200/60 px-2.5 py-1 font-medium text-stone-600 dark:bg-zinc-800/80 dark:text-zinc-300">
            {$t.promptForm.generate}
          </span>
          {#if activeSubmissions > 0}
            <span
              class="inline-flex items-center rounded-full bg-stone-200/60 px-2.5 py-1 font-mono text-[11px] font-medium text-stone-600 dark:bg-zinc-800/80 dark:text-zinc-300"
              data-testid="active-submissions-badge"
            >
              {$t.promptForm.activeSubmissions(activeSubmissions, MAX_CONCURRENT_SUBMISSIONS)}
            </span>
          {/if}
        {/if}
      </div>

      <div class="flex flex-col items-end gap-1">
        <button type="button" disabled={submitDisabled} class="ui-button-primary px-5 font-semibold" onclick={() => void handleSubmit()}>
          {$t.promptForm.startGenerate}
        </button>
        <p class="text-[11px] text-stone-400 dark:text-zinc-500">{$t.promptForm.submitShortcut}</p>
      </div>
    </div>
  </section>
</section>
