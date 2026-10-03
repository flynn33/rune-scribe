"""Guard the local Messages composer against a visible cipher invitation body."""

import os
from pathlib import Path
import unittest


DEFAULT_SOURCE = (
    Path(__file__).resolve().parents[2]
    / "Packages/RuneScribeArchitecture/Sources/RuneScribeUIRuntime/"
    "RuntimeInteractiveMessageComposeView.swift"
)


class CipherInvitationComposerContractTests(unittest.TestCase):
    def test_invitation_uses_message_artwork_and_url_without_visible_body(self):
        source = Path(os.environ.get("RUNE_INTERACTIVE_SOURCE", DEFAULT_SOURCE)).read_text()
        self.assertIn("message.url = invitation.URL", source)
        self.assertIn("message.layout = layout", source)
        self.assertIn("composer.message =", source)
        self.assertFalse(
            "Rune Scribe invitation fallback" in source,
            "factory still supplies visible invitation fallback text",
        )
        self.assertFalse(
            "composer.body =" in source,
            "composer still assigns a visible text body",
        )


if __name__ == "__main__":
    unittest.main()
