#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("collect-opengl-inventory.py")
SPEC = importlib.util.spec_from_file_location("dory_opengl_inventory", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
INVENTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INVENTORY)


class OpenGLInventoryTests(unittest.TestCase):
    def test_glxinfo_requires_renderer_and_mesa_version(self) -> None:
        value = ("OpenGL renderer string: zink (Venus)\n"
                 "OpenGL core profile version string: 4.6 (Core Profile) Mesa 25.0.1\n")
        self.assertEqual(INVENTORY.glxinfo_fields(value),
                         ("zink (Venus)", "4.6 (Core Profile) Mesa 25.0.1", "25.0.1"))
        with self.assertRaisesRegex(INVENTORY.InventoryError, "Mesa version"):
            INVENTORY.glxinfo_fields("OpenGL renderer string: llvmpipe\n")

    def test_probe_capabilities_must_be_actual_sorted_used_lists(self) -> None:
        result = {
            "schema": "dev.dory.gpu-probe", "version": 1,
            "probe": "vulkan-application", "deviceName": "Venus", "driver": "venus",
            "apiVersion": "1.3", "extensionsUsed": ["VK_KHR_swapchain"],
            "featuresUsed": ["dynamicRendering"],
            "frameCount": 1, "nonce": "challenge-1",
            "resultHash": "fnv1a64:0123456789abcdef", "visualChallenge": {},
            "strategyFeatureFallback": False,
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "probe.json"
            path.write_text(json.dumps(result))
            self.assertEqual(INVENTORY.probe_result(path, "vulkan-application")[0], result)
            indirect = Path(temporary) / "indirect-probe.json"
            indirect.symlink_to(path)
            with self.assertRaises(OSError):
                INVENTORY.probe_result(indirect, "vulkan-application")
            result["extensionsUsed"] = ["VK_KHR_swapchain", "VK_EXT_robustness2"]
            path.write_text(json.dumps(result))
            with self.assertRaisesRegex(INVENTORY.InventoryError, "sorted unique"):
                INVENTORY.probe_result(path, "vulkan-application")
            result["extensionsUsed"] = ["VK_KHR_swapchain"]
            path.write_text(json.dumps(result))
            with self.assertRaisesRegex(INVENTORY.InventoryError, "matching Dory GPU probe"):
                INVENTORY.probe_result(path, "gl")


if __name__ == "__main__":
    unittest.main()
