"""Both app variants must keep independent identities, roots and renderer profiles.

Native workers operate only on scratch directories. No Wine or Steam runs here.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from build_portable_setup import build


class GPTK4Variant(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='macvolvo-variant-build-')
        cls.addClassCleanup(cls.temp.cleanup)
        folder = Path(cls.temp.name)
        cls.workers, cls.brands, cls.profiles = {}, {}, {}
        worker = (ROOT / 'scripts/portable_setup.m').read_text()
        env = worker[worker.index('static NSMutableDictionary *wineEnv('):worker.index('static NSTask *task(')]
        harness = r'''#import <Foundation/Foundation.h>
#include "candidate_contract.generated.h"
static NSString *root=@"/fixture";
static NSFileManager *fm;
static NSString *join(NSString *a,NSString *b) {return [a stringByAppendingPathComponent:b];}
static NSString *gameList(NSString *separator) {return [@[@"cs2.exe",@"deadlock.exe"] componentsJoinedByString:separator];}
''' + env + r'''
int main(void) {@autoreleasepool {
    fm=NSFileManager.defaultManager;
    NSData *data=[NSJSONSerialization dataWithJSONObject:wineEnv(@"/fixture/engine") options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout);
}}
'''
        env_path = folder / 'environment.m'
        env_path.write_text(harness)
        brand_path = folder / 'VariantProbe.swift'
        brand_path.write_text('''import Foundation
@main struct Probe {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let result:[String:Any]=["name":Brand.name,"id":Brand.bundleIdentifier,
            "folder":InstallLocation.folderName,"marker":Brand.ownerMarker,
            "updates":Brand.allowsUpdates,"problem":InstallLocation.problem(for:root) ?? ""]
        print(String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!)
    }
}
''')
        for variant, defines in (('dxmt', ()), ('gptk4', ('MACVOLVO_GPTK4',))):
            binary = folder / variant / 'ow2-setup'
            build(binary, ROOT / 'runtime/toolchains/libarchive-3.7.7', defines=defines)
            cls.workers[variant] = binary
            profile = folder / (variant + '-environment')
            subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                            '-Wno-unused-function', *('-D' + d for d in defines),
                            '-I', str(ROOT / 'scripts'), str(env_path), '-framework',
                            'Foundation', '-o', str(profile)], check=True, capture_output=True)
            cls.profiles[variant] = json.loads(subprocess.check_output([str(profile)]))
            brand = folder / (variant + '-brand')
            result=subprocess.run(['swiftc', '-parse-as-library', '-target', 'arm64-apple-macos26.5',
                            *(['-D', 'MACVOLVO_GPTK4'] if defines else []),
                            str(ROOT / 'app/Sources/Brand.swift'),
                            str(ROOT / 'app/Sources/InstallLocation.swift'),
                            str(brand_path), '-o', str(brand)], capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError(result.stderr)
            cls.brands[variant] = brand

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix='macvolvo-variant-roots-')
        self.addCleanup(self.fixture.cleanup)
        self.base = Path(self.fixture.name)

    def call(self, variant, root):
        result = subprocess.run([str(self.workers[variant]), 'status', '--root', str(root)],
                                capture_output=True, text=True, timeout=15)
        return result, json.loads(result.stdout.splitlines()[-1])

    def test_distinct_markers_and_mutual_root_rejection(self):
        roots = {v: self.base / v for v in self.workers}
        for variant, root in roots.items():
            result, _ = self.call(variant, root)
            self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((roots['dxmt'] / '.macvolvo-owner').is_file())
        self.assertTrue((roots['gptk4'] / '.macvolvo-gptk4-owner').is_file())
        for variant, other in (('dxmt', 'gptk4'), ('gptk4', 'dxmt')):
            for root in (roots[other], roots[other] / 'nested'):
                result, row = self.call(variant, root)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(row['code'], 'directory_not_owned_by_app')
            self.assertFalse((roots[other] / 'nested').exists())

    def test_swift_identity_and_location_checks_match_worker_variant(self):
        for variant, name, marker, bundle in (
                ('dxmt', 'MacVolvo', '.macvolvo-owner', 'app.macvolvo.launcher'),
                ('gptk4', 'MacVolvo GPTK4', '.macvolvo-gptk4-owner', 'app.macvolvo.gptk4')):
            root = self.base / variant
            root.mkdir()
            result = json.loads(subprocess.check_output([str(self.brands[variant]), str(root)]))
            self.assertEqual((result['name'], result['folder'], result['marker'], result['id']),
                             (name, name, marker, bundle))
            self.assertEqual(result['updates'], variant == 'dxmt')
            other_marker = '.macvolvo-owner' if variant == 'gptk4' else '.macvolvo-gptk4-owner'
            (root / other_marker).write_text('owned by other variant')
            result = json.loads(subprocess.check_output([str(self.brands[variant]), str(root / 'nested')]))
            self.assertIn('other MacVolvo app', result['problem'])

    def test_renderer_profiles_switch_modules_without_changing_wine_session_settings(self):
        baseline, evaluation = self.profiles['dxmt'], self.profiles['gptk4']
        self.assertEqual(baseline['CX_GRAPHICS_BACKEND'], 'dxmt')
        self.assertTrue(any(key.startswith('DXMT_') for key in baseline))
        self.assertEqual(evaluation['CX_GRAPHICS_BACKEND'], 'd3dmetal')
        self.assertFalse(any(key.startswith('DXMT_') for key in evaluation))
        self.assertEqual(evaluation['WINEDLLOVERRIDES'],
                         'd3d11,dxgi,d3d10=b;d3d10core,winemetal,d3d12,d3d12core,nvapi64,nvngx=')
        self.assertEqual(evaluation['D3DM_ENABLE_METALFX'], '0')
        self.assertEqual(evaluation['MACVOLVO_GPTK4_DISPLAY_FIX'], '1')
        self.assertNotIn('MACVOLVO_GPTK4_DISPLAY_FIX', baseline)
        self.assertEqual(evaluation['D3DMETAL_FRAMEWORK_PATH'],
                         '/fixture/engine/lib/external/D3DMetal.framework/D3DMetal')
        self.assertNotIn('D3DM_MTL4', evaluation)
        for key in ('WINEMSYNC', 'WINEESYNC', 'WINEPREFIX', 'ROSETTA_ADVERTISE_AVX',
                    'WINEMAC_MOUSELOOK', 'WINE_GAME_MODE', 'WEBHELPER_EXTRA_ARGS'):
            self.assertEqual(baseline[key], evaluation[key], key)


if __name__ == '__main__':
    unittest.main()
