"""Exercise real Steam window-request/running-session code with disposable stubs."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class RunningActions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='macvolvo-running-actions-')
        cls.addClassCleanup(cls.temp.cleanup)
        worker = (ROOT / 'scripts/portable_setup.m').read_text()
        helper = block(worker, 'static void openSteamWindow(')
        branch = block(worker[worker.index('static void launchClient('):], '    if(running) {')
        harness = r'''#import <Foundation/Foundation.h>
static NSArray *focused=@[],*arguments=@[];
static NSString *stage=@"",*executable=@"";
static int deadline,exitCode;
static BOOL focusSession(NSArray *rows) {focused=rows;return rows.count>0;}
static NSString *join(NSString *a,NSString *b) {return [a stringByAppendingPathComponent:b];}
static NSString *clientPath(void) {return @"/owned/steam.exe";}
static NSMutableDictionary *wineEnv(NSString *engine) {(void)engine;return [NSMutableDictionary dictionary];}
static NSMutableDictionary *clientEnvironment(NSMutableDictionary *env,BOOL hud,BOOL gameMode) {
    (void)hud;(void)gameMode;return env;
}
static NSTask *task(NSString *path,NSArray *args,NSDictionary *env,NSString *log) {
    (void)env;(void)log;executable=path;arguments=args;return [NSTask new];
}
static int waitTask(NSTask *p,int seconds) {(void)p;deadline=seconds;return exitCode;}
static void fail(NSString *code) {@throw [NSException exceptionWithName:@"FixtureError" reason:code userInfo:nil];}
static void event(NSString *name,id details) {(void)details;stage=name;}
''' + helper + r'''
static void run(NSArray *existing,BOOL game) {
    BOOL running=YES,hud=NO,gameMode=YES;NSString *engine=@"/owned/engine";
''' + branch + r'''
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc!=2)return 2;
    NSString *mode=@(argv[1]),*error=@"";
    NSArray *rows=@[@{@"kind":@"game",@"pid":@11},@{@"kind":@"client",@"pid":@12}];
    if([mode isEqual:@"missing"])rows=@[rows[0]];
    if([mode isEqual:@"failed"])exitCode=1;
    @try {run(rows,[mode isEqual:@"play"]);}
    @catch(NSException *exception) {error=exception.reason;}
    NSDictionary *out=@{@"focused":focused,@"arguments":arguments,@"stage":stage,
                        @"executable":executable,@"deadline":@(deadline),@"error":error};
    NSData *data=[NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout);return 0;
}}
'''
        path = Path(cls.temp.name) / 'actions.m'
        path.write_text(harness)
        cls.binary = path.with_suffix('')
        subprocess.run(['/usr/bin/clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        '-framework', 'Foundation', str(path), '-o', str(cls.binary)],
                       check=True, capture_output=True)

    def call(self, mode):
        return json.loads(subprocess.check_output([str(self.binary), mode], timeout=5))

    def test_open_steam_sends_window_request_instead_of_only_activating_process(self):
        result = self.call('open')
        self.assertEqual(result['arguments'], ['/owned/steam.exe', '-no-cef-sandbox',
                                               '-noverifyfiles', 'steam://open/main'])
        self.assertEqual(result['executable'], '/owned/engine/bin/wine')
        self.assertEqual(result['deadline'], 15)
        self.assertEqual(result['stage'], 'steam_window_requested')
        self.assertEqual(result['focused'], [])
        self.assertEqual(result['error'], '')

    def test_play_focuses_existing_game_without_requesting_another_process(self):
        result = self.call('play')
        self.assertEqual(result['focused'][0]['kind'], 'game')
        self.assertEqual(result['arguments'], [])
        self.assertEqual(result['deadline'], 0)

    def test_missing_client_is_reported_without_starting_steam_or_stopping_game(self):
        result = self.call('missing')
        self.assertEqual(result['error'], 'steam_client_not_running')
        self.assertEqual(result['arguments'], [])
        self.assertEqual(result['stage'], '')

    def test_request_failure_does_not_report_success(self):
        result = self.call('failed')
        self.assertEqual(result['error'], 'steam_window_request_failed')
        self.assertEqual(result['stage'], '')
        self.assertEqual(result['deadline'], 15)


if __name__ == '__main__':
    unittest.main()
