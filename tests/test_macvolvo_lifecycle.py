"""Production launch/close paths with disposable native children, never real Wine.

Only the Wine commands and process inventory are fixtures. The worker's task,
timeout, Steam handoff branch, and shutdown functions are compiled unchanged,
except that command deadlines are shortened for the timeout tests.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
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


class SteamLifecycle(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='macvolvo-lifecycle-build-')
        cls.addClassCleanup(cls.build.cleanup)
        folder = Path(cls.build.name)
        worker = (ROOT / 'scripts/portable_setup.m').read_text()
        tasks = worker[worker.index('static NSTask *task('):worker.index('static BOOL busy(')]
        tasks = tasks.replace('return waitTaskTicking(p,seconds,nil);',
                              'return waitTaskTicking(p,([mode isEqual:@"hang"] || [mode isEqual:@"stubborn"]) ? 2 : seconds,nil);')
        launch = worker[worker.index('static void launchClient('):]
        request = block(launch, '    if(existing.count) {')
        end_session = block(worker, 'static void endSession(')
        close_client = block(worker, 'static void closeClient(NSString *gameRunning) {')
        source = r'''#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>
static NSString *root, *mode;
static NSFileManager *fm;
static NSMutableArray *events;
static NSMutableDictionary *membershipCache;
static volatile sig_atomic_t childPID, cancelRequested;
static int inventoryCalls;
static NSString *join(NSString *a,NSString *b) {return [a stringByAppendingPathComponent:b];}
static void fail(NSString *code) {@throw [NSException exceptionWithName:@"SetupError" reason:code userInfo:nil];}
static void event(NSString *stage,NSDictionary *details) {(void)details;[events addObject:stage];}
static NSString *runtime(void) {return join(root,@"runtimes/v1");}
static NSDictionary *state(void) {return @{@"active_runtime":@"v1"};}
static BOOL matches(NSString *text,NSString *pattern) {
    return [text rangeOfString:pattern options:NSRegularExpressionSearch].location!=NSNotFound;
}
static NSDictionary *wineEnv(NSString *engine) {(void)engine;return @{@"TEST_ROOT":root,@"TEST_MODE":mode};}
static NSDictionary *clientEnvironment(NSDictionary *env,BOOL hud,BOOL gameMode) {
    (void)hud;(void)gameMode;return env;
}
static void configureVoiceMicrophone(NSString *engine,id forced,BOOL apply,BOOL settle) {
    (void)engine;(void)forced;(void)apply;(void)settle;
}
static void focusSession(NSArray *rows) {(void)rows;}
static void openSteamWindow(NSString *engine,NSArray *rows,BOOL hud,BOOL gameMode) {
    (void)engine;(void)rows;(void)hud;(void)gameMode;
}
static NSString *clientPath(void) {return join(root,@"steam.exe");}
static NSArray *sessionProcesses(void) {
    int call=inventoryCalls++;
    if([mode isEqual:@"game"] || (([mode isEqual:@"late-game"] || [mode isEqual:@"last-moment-game"]) && call>0))
        return @[@{@"kind":@"game",@"pid":@99}];
    if(([mode isEqual:@"client"] || [mode isEqual:@"late-game"]) && call==0)
        return @[@{@"kind":@"client",@"pid":@98}];
    return @[];
}
''' + tasks + end_session + close_client + r'''
typedef struct {NSString *key;} FixtureGame;
static void requestGame(void) {
    NSString *engine=runtime();BOOL hud=NO,gameMode=YES;
    FixtureGame chosen={@"cs2"};FixtureGame *game=&chosen;
    NSArray *existing=@[@{@"kind":@"client"}];
    NSMutableArray *client=[@[clientPath(),@"-applaunch",@"730"] mutableCopy];
''' + request + r'''
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc!=4)return 2;
    root=@(argv[1]);mode=@(argv[3]);fm=NSFileManager.defaultManager;events=[NSMutableArray array];
    NSString *code=@"ok";
    @try {
        if(!strcmp(argv[2],"request"))requestGame();
        else if(!strcmp(argv[2],"close"))closeClient(@"game_running");
        else endSession(runtime());
    } @catch(NSException *error) {code=error.reason;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"code":code,@"events":events} options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout);return 0;
}}
'''
        path = folder / 'lifecycle.m'
        path.write_text(source)
        cls.binary = folder / 'lifecycle'
        subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        '-Wno-unused-function', str(path), '-framework', 'Foundation',
                        '-o', str(cls.binary)], check=True, capture_output=True)
        fixture = folder / 'fixture.c'
        fixture.write_text(r'''
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char **argv) {
    char path[4096];const char *root=getenv("TEST_ROOT"),*mode=getenv("TEST_MODE");
    if(strstr(argv[0],"wineserver")) {
        snprintf(path,sizeof(path),"%s/server.calls",root);
        FILE *f=fopen(path,"a");fprintf(f,"%s\n",argc>1?argv[1]:"?");fclose(f);
        return argc>1 && ((!strcmp(argv[1],"-w") && !strcmp(mode,"wait-fails")) ||
                          (!strcmp(argv[1],"-k") && !strcmp(mode,"kill-fails"))) ? 7 : 0;
    }
    if(argc>2 && !strcmp(argv[2],"-shutdown"))return 0;
    snprintf(path,sizeof(path),"%s/request.pid",root);
    FILE *f=fopen(path,"w");fprintf(f,"%d",getpid());fclose(f);
    if(!strcmp(mode,"hang") || !strcmp(mode,"stubborn")) {
        if(!strcmp(mode,"stubborn"))signal(SIGTERM,SIG_IGN);
        for(;;)pause();
    }
    usleep(50000);return !strcmp(mode,"fails") ? 7 : 0;
}
''')
        cls.fixture = folder / 'fixture'
        subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', str(fixture),
                        '-o', str(cls.fixture)], check=True, capture_output=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='macvolvo-lifecycle-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'logs').mkdir()
        engine = self.root / 'runtimes/v1'
        (engine / 'bin').mkdir(parents=True)
        (engine / 'runtime.json').write_text('{}')
        for name in ('wine', 'wineserver'):
            shutil.copy2(self.fixture, engine / 'bin' / name)
        self.request_pids = []
        self.addCleanup(self.cleanup_requests)

    def cleanup_requests(self):
        for pid in self.request_pids:
            try:
                name = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'comm='],
                                      capture_output=True, text=True).stdout.strip()
                if name == str(self.root / 'runtimes/v1/bin/wine'):
                    os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def call(self, command, mode='normal'):
        result = subprocess.run([str(self.binary), str(self.root), command, mode],
                                capture_output=True, text=True, check=True, timeout=12)
        if command == 'request':
            pidfile = self.root / 'request.pid'
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                if pidfile.exists() and pidfile.read_text().strip().isdigit():
                    break
                time.sleep(.01)
            if pidfile.exists() and pidfile.read_text().strip().isdigit():
                self.request_pids.append(int(pidfile.read_text()))
                pidfile.unlink()
        return json.loads(result.stdout)

    def server_calls(self):
        path = self.root / 'server.calls'
        return path.read_text().splitlines() if path.exists() else []

    def test_handoff_finishes_before_success_is_reported(self):
        result = self.call('request')
        self.assertEqual(result['code'], 'ok')
        self.assertIn('game_launch_requested', result['events'])
        with self.assertRaises(ProcessLookupError):
            os.kill(self.request_pids[-1], 0)
        self.assertEqual(self.server_calls(), [])

    def test_failed_handoff_is_reported_without_resetting_steam(self):
        result = self.call('request', 'fails')
        self.assertEqual(result['code'], 'steam_launch_request_failed')
        self.assertNotIn('game_launch_requested', result['events'])
        self.assertEqual(self.server_calls(), [])

    def test_repeated_hung_handoffs_leave_no_requesters_or_signal_other_processes(self):
        sentinels = [subprocess.Popen(['/bin/sleep', '30']) for _ in range(3)]
        try:
            for mode in ('hang', 'hang', 'stubborn'):
                result = self.call('request', mode)
                self.assertEqual(result['code'], 'steam_launch_request_failed')
                with self.assertRaises(ProcessLookupError):
                    os.kill(self.request_pids[-1], 0)
                self.assertTrue(all(p.poll() is None for p in sentinels))
                self.assertEqual(self.server_calls(), [])
        finally:
            for process in sentinels:
                process.terminate()
                process.wait(timeout=5)

    def test_close_ends_leftover_services_and_waits_for_server_exit(self):
        for mode in ('normal', 'client'):
            with self.subTest(mode=mode):
                calls = self.root / 'server.calls'
                calls.unlink(missing_ok=True)
                self.assertEqual(self.call('close', mode)['code'], 'ok')
                self.assertEqual(self.server_calls(), ['-k', '-w'])

    def test_game_running_or_appearing_during_close_prevents_server_shutdown(self):
        for mode in ('game', 'late-game', 'last-moment-game'):
            with self.subTest(mode=mode):
                self.assertEqual(self.call('close', mode)['code'], 'game_running')
                self.assertEqual(self.server_calls(), [])

    def test_close_does_not_report_success_when_server_cannot_exit(self):
        self.assertEqual(self.call('close', 'wait-fails')['code'], 'client_close_failed')

    def test_failed_shutdown_request_is_reported_without_waiting_for_exit(self):
        self.assertEqual(self.call('close', 'kill-fails')['code'], 'client_close_failed')
        self.assertEqual(self.server_calls(), ['-k'])


if __name__ == '__main__':
    unittest.main()
