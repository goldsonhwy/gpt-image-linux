<script lang="ts">
  import { t } from '$lib/i18n';

  export let hasNext = false;
  export let loading = false;
  export let onLoadMore: () => void = () => {};
</script>

{#if hasNext}
  <div class="mt-5 flex justify-center">
    <button
      type="button"
      disabled={loading}
      on:click={onLoadMore}
      class="ui-button-secondary text-xs disabled:cursor-not-allowed disabled:opacity-50"
    >
      {loading ? $t.gallery.loadingMore : $t.gallery.loadMore}
    </button>
  </div>
{/if}
