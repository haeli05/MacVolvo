"""Steam browser repair against disposable files; never starts Steam or Wine."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MARK = 'steamwebhelper_real.exe'.encode('utf-16le')
WRAPPER = b'MZ fixture wrapper ' + MARK


class SteamWindowFix(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='macvolvo-browser-build-')
        cls.addClassCleanup(cls.build.cleanup)
        folder = Path(cls.build.name)
        header = (ROOT/'scripts/portable_steam.h').read_text()
        production = header[header.index('/* Whether a file is the stand-in:'):header.index('/* Steam lays itself out')]
        source = r'''#import <Foundation/Foundation.h>
static NSString *root;
static NSFileManager *fm;
static BOOL gpuEnabled;
static NSString *join(NSString *a,NSString *b) {return [a stringByAppendingPathComponent:b];}
static NSString *steamFolder(void) {return join(root,@"steam");}
static NSString *helperPath(NSString *name) {(void)name;return join(root,@"bundled.exe");}
static void fail(NSString *code) {@throw [NSException exceptionWithName:@"FixtureError" reason:code userInfo:nil];}
static NSString *hashFile(NSString *path) {return [[NSData dataWithContentsOfFile:path] base64EncodedStringWithOptions:0];}
static void event(NSString *stage,NSDictionary *details) {(void)stage;(void)details;}
static BOOL registryValue(NSString *engine,NSString *key,NSString *name,NSString *type,NSString *value,NSString *log) {
    (void)engine;(void)key;(void)type;(void)log;
    gpuEnabled=[name isEqual:@"GPUAccelWebViewsV3"] && [value isEqual:@"1"];return YES;
}
''' + production + r'''
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc!=2)return 2;
    root=@(argv[1]);fm=NSFileManager.defaultManager;
    NSDictionary *result;
    @try {
        BOOL needed=steamWindowFixNeeded(),fixed=steamWindowFix(@"fixture-engine");
        result=@{@"needed":@(needed),@"fixed":@(fixed),@"still_needed":@(steamWindowFixNeeded()),@"gpu_enabled":@(gpuEnabled)};
    } @catch(NSException *error) {result=@{@"error":error.reason};}
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout);return 0;
}}
'''
        path = folder/'browser.m'
        path.write_text(source)
        cls.binary = folder/'browser-tests'
        subprocess.run(['/usr/bin/clang','-fobjc-arc','-Wall','-Wextra','-Werror',str(path),
                        '-framework','Foundation','-o',str(cls.binary)],check=True,capture_output=True)
        worker = (ROOT/'scripts/portable_setup.m').read_text()
        decision = worker[worker.index('    BOOL needsOptions=NO;'):worker.index('    if(!configureDeadlockRenderer())')]
        source = r'''#import <Foundation/Foundation.h>
static BOOL needsRepair,closed,settled,configured;
static BOOL steamWindowFixNeeded(void) {return needsRepair;}
static BOOL steamLaunchOptionsNeedUpdate(NSDictionary *options,BOOL *needs) {(void)options;*needs=NO;return YES;}
static NSDictionary *state(void) {return @{@"session_hud":@NO,@"session_game_mode":@YES};}
static void fail(NSString *code) {(void)code;abort();}
static void event(NSString *stage,id details) {(void)stage;(void)details;}
static void closeClient(NSString *guard) {(void)guard;closed=YES;}
static void endSession(NSString *engine) {(void)engine;settled=YES;}
static BOOL configureSteamLaunchOptions(NSDictionary *options) {(void)options;configured=YES;return YES;}
static void run(void) {
    NSArray *existing=@[@{@"kind":@"client"}];
    NSDictionary *defaults=@{};NSString *engine=@"fixture",*sessionDisplays=nil;
    BOOL hud=NO,gameMode=YES,displaysChanged=NO;
''' + decision + r'''
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc!=2)return 2;needsRepair=atoi(argv[1]);run();
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"closed":@(closed),@"settled":@(settled),@"configured":@(configured)} options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout);return 0;
}}
'''
        path = folder/'reopen.m'
        path.write_text(source)
        cls.reopen = folder/'reopen-tests'
        subprocess.run(['/usr/bin/clang','-fobjc-arc','-Wall','-Wextra','-Werror',str(path),
                        '-framework','Foundation','-o',str(cls.reopen)],check=True,capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='macvolvo-browser-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cef = self.root/'steam/bin/cef/cef.win64'
        self.cef.mkdir(parents=True)
        self.helper = self.cef/'steamwebhelper.exe'
        self.real = self.cef/'steamwebhelper_real.exe'
        (self.root/'bundled.exe').write_bytes(WRAPPER)

    def call(self):
        result = subprocess.run([str(self.binary),str(self.root)],capture_output=True,text=True,check=True,timeout=5)
        return json.loads(result.stdout)

    def test_first_update_helper_is_replaced_and_original_preserved(self):
        self.helper.write_bytes(b'MZ Steam browser')
        self.assertEqual(self.call(),{'needed':True,'fixed':True,'still_needed':False,'gpu_enabled':True})
        self.assertEqual(self.helper.read_bytes(),WRAPPER)
        self.assertEqual(self.real.read_bytes(),b'MZ Steam browser')

    def test_steam_update_replaces_old_real_helper(self):
        self.helper.write_bytes(b'MZ new Steam browser')
        self.real.write_bytes(b'MZ old Steam browser')
        self.assertTrue(self.call()['needed'])
        self.assertEqual(self.real.read_bytes(),b'MZ new Steam browser')

    def test_old_wrapper_is_updated_without_replacing_real_browser(self):
        self.helper.write_bytes(WRAPPER+b' older build')
        self.real.write_bytes(b'MZ Steam browser')
        self.assertTrue(self.call()['needed'])
        self.assertEqual(self.helper.read_bytes(),WRAPPER)
        self.assertEqual(self.real.read_bytes(),b'MZ Steam browser')

    def test_current_wrapper_needs_no_restart(self):
        self.helper.write_bytes(WRAPPER)
        self.real.write_bytes(b'MZ Steam browser')
        self.assertFalse(self.call()['needed'])

    def test_missing_or_recursive_real_browser_is_restored_by_steam(self):
        for real in (None,WRAPPER):
            with self.subTest(real=real):
                self.helper.write_bytes(WRAPPER)
                if real is not None:
                    self.real.write_bytes(real)
                result = self.call()
                self.assertTrue(result['needed'])
                self.assertFalse(result['fixed'])
                self.assertFalse(self.helper.exists())
                self.assertFalse(self.real.exists())

    def test_bootstrap_without_browser_is_left_to_steam(self):
        self.assertEqual(self.call(),{'needed':False,'fixed':False,'still_needed':False,'gpu_enabled':False})
        self.assertFalse(self.helper.exists())

    def test_idle_steam_reopens_only_when_browser_needs_repair(self):
        for repair in (False,True):
            with self.subTest(repair=repair):
                result = subprocess.run([str(self.reopen),str(int(repair))],capture_output=True,text=True,check=True,timeout=5)
                self.assertEqual(json.loads(result.stdout),dict.fromkeys(('closed','settled','configured'),repair))


if __name__ == '__main__':
    unittest.main()
