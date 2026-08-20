-- Dory's virtio-snd device intentionally has no legacy analog mixer or UCM description. ACP
-- therefore exposes only its generic Pro Audio profile, which WirePlumber 0.4 will not select
-- automatically. Activate that profile so both the speaker and microphone nodes are present from
-- the beginning of every desktop session.
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "device.name", "matches", "alsa_card.platform-*.virtio_mmio" },
      { "device.nick", "matches", "VirtIO SoundCard" },
    },
  },
  apply_properties = {
    ["device.profile"] = "pro-audio",
    ["device.description"] = "Dory Audio",
    ["device.nick"] = "Dory Audio",
    ["api.alsa.use-acp"] = true,
    ["api.alsa.use-ucm"] = false,
    ["api.alsa.soft-mixer"] = true,
    ["api.alsa.ignore-dB"] = true,
    ["api.acp.auto-profile"] = false,
    ["api.acp.auto-port"] = false,
  },
})

-- Pro Audio normally puts every PCM direction in one start/stop group. Dory maps speaker and
-- microphone onto independent Mac audio graphs, so group them independently as well: opening
-- Firefox must not start an unused microphone, and recording must not keep an unused speaker
-- running. Expose conventional stereo channel names instead of the generic AUX labels produced
-- without a UCM profile.
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_output.platform-*.virtio_mmio.pro-output-*" },
    },
  },
  apply_properties = {
    ["node.pause-on-idle"] = true,
    ["node.group"] = "dory-playback",
    ["node.link-group"] = "dory-playback",
    ["audio.position"] = "FL,FR",
  },
})

table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_input.platform-*.virtio_mmio.pro-input-*" },
    },
  },
  apply_properties = {
    ["node.pause-on-idle"] = true,
    ["node.group"] = "dory-capture",
    ["node.link-group"] = "dory-capture",
    ["audio.position"] = "FL,FR",
  },
})
