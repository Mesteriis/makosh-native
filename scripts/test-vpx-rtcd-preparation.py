import unittest
from pathlib import Path

from vpx_rtcd_preparation import portable_prototypes


class PortableRTCDTests(unittest.TestCase):
    def test_only_active_portable_prototypes_are_emitted(self):
        # A disabled encoder/high-bit-depth branch must never enter our C-only
        # public header, while else/nested OR conditions keep decoder functions.
        source = '''
add_proto qw/void common/, "int value";
if (vpx_config("CONFIG_VP9_ENCODER") eq "yes") {
  add_proto qw/void encoder/, "int value";
} else {
  if (vpx_config("CONFIG_VP9") eq "yes" || vpx_config("CONFIG_VP8") eq "yes") {
    add_proto qw/unsigned int decoder/, "const uint8_t *data";
  }
}
if (vpx_config("CONFIG_VP9_HIGHBITDEPTH") ne "yes") {
  add_proto qw/void eight_bit/, "int value";
}
if ($opts{arch} eq "x86_64") {
  add_proto qw/void assembly_only/, "int value";
}
'''
        self.assertEqual(portable_prototypes(source, {"CONFIG_VP9"}), [
            ("void", "common", "int value"),
            ("unsigned int", "decoder", "const uint8_t *data"),
            ("void", "eight_bit", "int value"),
        ])

    def test_unknown_program_and_unbalanced_branches_fail_closed(self):
        # A changed upstream generator must require review; no Perl, eval,
        # subprocess, or silently omitted new condition is permitted.
        for text in [
            'system("unexpected");',
            'if (vpx_config("CONFIG_VP9") =~ /yes/) {\n}\n',
            'if (vpx_config("CONFIG_VP9") eq "yes") {\n',
            '}\n',
            'add_proto qw/void common/, dynamic_arguments();',
        ]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                portable_prototypes(text, {"CONFIG_VP9"})

    def test_duplicate_native_symbol_is_rejected(self):
        # Duplicate aliases could silently bind one C signature to another.
        with self.assertRaises(ValueError):
            portable_prototypes('''
add_proto qw/void same/, "int value";
add_proto qw/int same/, "const char *value";
''', set())

    def test_reviewed_literal_specialization_cannot_enable_assembly(self):
        # The pinned DSP declaration has a literal architecture-variable suffix;
        # it is recognized as metadata and must not change the portable binding.
        try:
            actual = portable_prototypes('''
add_proto qw/void common/, "int value";
specialize qw/common avx2 neon/, "$sse2_x86_64";
''', set())
        except ValueError:
            self.fail("Reviewed specialization metadata was rejected")
        self.assertEqual(actual, [("void", "common", "int value")])

    def test_pinned_decoder_declarations_include_required_eight_bit_functions(self):
        # The actual reviewed declaration inputs must produce the portable
        # decoder API and must exclude disabled encoder/high-bit-depth APIs.
        root = Path(__file__).resolve().parent.parent / ".local/vpx-codec/Provenance"
        required = {
            "vp9/common/vp9_rtcd_defs.pl": {"vp9_iht4x4_16_add", "vp9_iht8x8_64_add", "vp9_iht16x16_256_add"},
            "vpx_dsp/vpx_dsp_rtcd_defs.pl": {"vpx_convolve8", "vpx_idct4x4_16_add", "vpx_d207_predictor_4x4"},
            "vpx_scale/vpx_scale_rtcd.pl": {"vpx_extend_frame_borders", "vpx_yv12_copy_frame"},
        }
        for relative, names in required.items():
            with self.subTest(relative=relative):
                try:
                    actual = portable_prototypes((root / relative).read_text(), {"CONFIG_VP9", "CONFIG_VP9_DECODER", "CONFIG_DECODERS"})
                except ValueError as error:
                    self.fail(str(error))
                symbols = {name for _, name, _ in actual}
                self.assertTrue(names <= symbols)
                self.assertFalse(any("highbd" in name for name in symbols))
                self.assertNotIn("vp9_block_error", symbols)


if __name__ == "__main__":
    unittest.main()
