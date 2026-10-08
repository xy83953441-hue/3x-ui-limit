<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import { Protocols } from '@/models/inbound.js';
import QrPanel from './QrPanel.vue';

const { t } = useI18n();
const props = defineProps({
  open: { type: Boolean, default: false },
  dbInbound: { type: Object, default: null },
  client: { type: Object, default: null },
  remarkModel: { type: String, default: '-ieo' },
  nodeAddress: { type: String, default: '' },
  subSettings: {
    type: Object,
    default: () => ({ enable: false, subURI: '', subJsonURI: '', subJsonEnable: false, subClashURI: '', subClashEnable: false }),
  },
});

const emit = defineEmits(['update:open']);

const links = ref([]);
const wireguardConfigs = ref([]);
const wireguardLinks = ref([]);
const subLink = ref('');
const subJsonLink = ref('');
const subClashLink = ref('');
const activeKeys = ref([]);

const qrItems = computed(() => {
  const items = [];
  if (subLink.value) {
    items.push({
      key: 'sub',
      header: t('subscription.title'),
      value: subLink.value,
    });
  }
  if (subClashLink.value) {
    items.push({
      key: 'sub-clash',
      header: `${t('subscription.title')} (Clash / FlClash)`,
      value: subClashLink.value,
    });
  }
  if (subJsonLink.value) {
    items.push({
      key: 'sub-json',
      header: `${t('subscription.title')} (JSON)`,
      value: subJsonLink.value,
    });
  }
  links.value.forEach((link, idx) => {
    items.push({
      key: `l${idx}`,
      header: link.remark || `Link ${idx + 1}`,
      value: link.link,
    });
  });
  wireguardConfigs.value.forEach((cfg, idx) => {
    items.push({
      key: `wc${idx}`,
      header: `Peer ${idx + 1} config`,
      value: cfg,
      downloadName: `peer-${idx + 1}.conf`,
    });
    if (wireguardLinks.value[idx]) {
      items.push({
        key: `wl${idx}`,
        header: `Peer ${idx + 1} link`,
        value: wireguardLinks.value[idx],
      });
    }
  });
  return items;
});

watch(() => props.open, (next) => {
  if (!next || !props.dbInbound) return;
  const inbound = props.dbInbound.toInbound();
  if (inbound.protocol === Protocols.WIREGUARD) {
    const peerRemark = props.client?.email
      ? `${props.dbInbound.remark}-${props.client.email}`
      : props.dbInbound.remark;
    wireguardConfigs.value = inbound.genWireguardConfigs(peerRemark, '-ieo', props.nodeAddress).split('\r\n');
    wireguardLinks.value = inbound.genWireguardLinks(peerRemark, '-ieo', props.nodeAddress).split('\r\n');
    links.value = [];
  } else {
    // When a client is provided we generate per-client share links;
    // otherwise (single-user SS) fall back to the inbound's settings.
    links.value = inbound.genAllLinks(props.dbInbound.remark, props.remarkModel, props.client, props.nodeAddress);
    wireguardConfigs.value = [];
    wireguardLinks.value = [];
  }

  const subId = props.client?.subId;
  // Use the server-provided base URL so custom subscription paths/domains work.
  subClashLink.value = props.subSettings?.enable && props.subSettings.subClashEnable
    && props.subSettings.subClashURI && subId
    ? props.subSettings.subClashURI.replace(/\/+$/, '') + '/' + subId
    : '';
  if (props.subSettings?.enable && subId) {
    subLink.value = (props.subSettings.subURI || '') + subId;
    subJsonLink.value = props.subSettings.subJsonEnable
      ? (props.subSettings.subJsonURI || '') + subId
      : '';
  } else {
    subLink.value = '';
    subJsonLink.value = '';
  }
  const open = [];
  if (subLink.value) open.push('sub');
  if (subClashLink.value) open.push('sub-clash');
  if (subJsonLink.value) open.push('sub-json');
  activeKeys.value = open;
});

function close() {
  emit('update:open', false);
}
</script>

<template>
  <a-modal :open="open" :title="t('qrCode')" :footer="null" width="420px" @cancel="close">
    <template v-if="dbInbound">
      <a-collapse v-model:active-key="activeKeys" ghost class="qr-collapse">
        <a-collapse-panel v-for="item in qrItems" :key="item.key" :header="item.header">
          <QrPanel :value="item.value" :remark="item.header" :download-name="item.downloadName || ''" />
        </a-collapse-panel>
      </a-collapse>
    </template>
  </a-modal>
</template>

<style scoped>
.qr-collapse :deep(.ant-collapse-content-box) {
  padding: 8px 0 0;
}
</style>
