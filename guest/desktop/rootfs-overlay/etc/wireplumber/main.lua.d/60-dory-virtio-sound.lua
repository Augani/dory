-- Dory's virtio-snd device intentionally has no legacy analog mixer or UCM description. The ALSA
-- udev monitor exposes a stable platform-card name and kernel card nickname for both Dory desktop
-- transports, but virtio-mmio does not publish PCI vendor/product properties. Requiring those
-- absent properties leaves ACP on its Off profile and PipeWire exposes only Dummy Output.
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "device.name", "matches", "alsa_card.platform-*" },
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

-- Dory maps speaker and microphone onto independent Mac audio graphs, so group them independently:
-- opening Firefox must not start an unused microphone, and recording must not keep an unused
-- speaker running. The exact node suffix differs between ACP's stereo fallback and Pro Audio, so
-- bind the stable card identity and direction instead.
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_output.platform-*" },
      { "alsa.card_name", "matches", "VirtIO SoundCard" },
    },
  },
  apply_properties = {
    ["node.pause-on-idle"] = true,
    ["node.group"] = "dory-playback",
    ["node.link-group"] = "dory-playback",
    ["audio.position"] = "FL,FR",
    ["priority.driver"] = 2500,
    ["priority.session"] = 2500,
  },
})

table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_input.platform-*" },
      { "alsa.card_name", "matches", "VirtIO SoundCard" },
    },
  },
  apply_properties = {
    ["node.pause-on-idle"] = true,
    ["node.group"] = "dory-capture",
    ["node.link-group"] = "dory-capture",
    ["audio.position"] = "FL,FR",
    ["priority.driver"] = 2500,
    ["priority.session"] = 2500,
  },
})
